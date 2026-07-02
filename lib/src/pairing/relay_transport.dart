import 'package:gene/src/crypto/primitives.dart';
import 'package:gene/src/messaging/message_crypto.dart';

/// One feed entry as it crosses the relay boundary: an author-signed, sealed
/// blob addressed by its monotonic sequence number. The relay stores and serves
/// these opaquely — only the two peers can open the ciphertext.
class FeedEntry {
  FeedEntry({
    required this.seq,
    required this.signature,
    required this.ciphertext,
  });

  final int seq;
  final List<int> signature;
  final List<int> ciphertext;
}

/// Thrown by [RelayTransport.appendEntry]/[RelayTransport.ackEntries] when the
/// feed hasn't been created yet, so the author can bind it (with its per-feed
/// key) and retry — feeds are created lazily on first send.
class FeedNotFoundException implements Exception {
  const FeedNotFoundException(this.feedId);

  final String feedId;

  @override
  String toString() => 'FeedNotFoundException: $feedId';
}

/// Thrown by [RelayTransport.appendEntry] when an entry with this seq is already
/// on the feed — it's effectively delivered, so a retried send treats it as
/// success rather than wedging.
class DuplicateSeqException implements Exception {
  const DuplicateSeqException(this.feedId, this.seq);

  final String feedId;
  final int seq;

  @override
  String toString() => 'DuplicateSeqException($feedId, seq=$seq)';
}

/// Thrown by [RelayTransport.appendEntry] when the seq is at or below the feed's
/// acked watermark — a cursor desync, not a transient error.
class StaleSeqException implements Exception {
  const StaleSeqException(this.feedId, this.seq);

  final String feedId;
  final int seq;

  @override
  String toString() => 'StaleSeqException($feedId, seq=$seq)';
}

/// The relay operations gene needs: pairing rendezvous, append-only signed
/// feeds, and ephemeral media. Abstracted so the client is tested against an
/// in-memory fake and runs against the real Worker in the app.
abstract interface class RelayTransport {
  // Pairing — the single-use sealed invite.
  Future<void> putInvite(String id, List<int> sealedPayload);
  Future<List<int>?> getInvite(String id);

  /// Returns false if the slot was already redeemed (single-use).
  Future<bool> redeemInvite(String id, List<int> sealedResponse);
  Future<List<int>?> pollRedeem(String id);

  // Feeds — append-only, per-feed-key-signed, capability-read.
  Future<void> createFeed(String id, List<int> authorPublicKey);

  /// Append a signed entry. Throws [FeedNotFoundException] if the feed isn't
  /// bound yet (the caller should create it and retry).
  Future<void> appendEntry(String feedId, FeedEntry entry);

  /// Entries with `seq > since`, ascending.
  Future<List<FeedEntry>> fetchEntries(String feedId, {int since = 0});

  /// Destroy delivered entries with `seq <= upTo`; returns how many were
  /// deleted. Throws [FeedNotFoundException] if the feed doesn't exist.
  Future<int> ackEntries(String feedId, int upTo);

  // Media — opaque, encrypted blobs.
  Future<void> putMedia(String id, List<int> bytes);
  Future<List<int>?> getMedia(String id);
  Future<void> deleteMedia(String id);
}

/// An in-memory relay mirroring the Worker's semantics for tests — including
/// per-feed signature verification and single-use redemption, so the full
/// client crypto path is exercised, not stubbed.
class InMemoryRelay implements RelayTransport {
  final Map<String, List<int>> _invites = {};
  final Map<String, List<int>> _redeems = {};
  final Map<String, List<int>> _feeds = {}; // feedId -> author public key
  final Map<String, List<FeedEntry>> _entries = {};
  final Map<String, int> _acked = {}; // feedId -> highest acked seq
  final Map<String, List<int>> _media = {};

  @override
  Future<void> putInvite(String id, List<int> sealedPayload) async {
    if (_invites.containsKey(id)) throw StateError('invite already exists');
    _invites[id] = sealedPayload;
  }

  @override
  Future<List<int>?> getInvite(String id) async => _invites[id];

  @override
  Future<bool> redeemInvite(String id, List<int> sealedResponse) async {
    if (_redeems.containsKey(id)) return false;
    _redeems[id] = sealedResponse;
    return true;
  }

  @override
  Future<List<int>?> pollRedeem(String id) async => _redeems[id];

  @override
  Future<void> createFeed(String id, List<int> authorPublicKey) async {
    // Pin the author key write-once, like the real relay (a second create with a
    // different key is a no-op the relay reports as 409 / success), so the fake
    // can't silently re-bind a feed's author and mask a double-create regression.
    _feeds.putIfAbsent(id, () => authorPublicKey);
  }

  @override
  Future<void> appendEntry(String feedId, FeedEntry entry) async {
    final authorKey = _feeds[feedId];
    if (authorKey == null) throw FeedNotFoundException(feedId);
    final authentic = await Crypto.verify(
      signedMessage(entry.seq, entry.ciphertext),
      entry.signature,
      authorKey,
    );
    if (!authentic) throw StateError('bad signature');
    if (entry.seq <= (_acked[feedId] ?? -1)) {
      throw StaleSeqException(feedId, entry.seq);
    }
    final list = _entries.putIfAbsent(feedId, () => <FeedEntry>[]);
    if (list.any((e) => e.seq == entry.seq)) {
      throw DuplicateSeqException(feedId, entry.seq);
    }
    list.add(entry);
  }

  @override
  Future<List<FeedEntry>> fetchEntries(String feedId, {int since = 0}) async {
    final list = _entries[feedId] ?? const <FeedEntry>[];
    return [for (final e in list) if (e.seq > since) e]
      ..sort((a, b) => a.seq.compareTo(b.seq));
  }

  @override
  Future<int> ackEntries(String feedId, int upTo) async {
    if (!_feeds.containsKey(feedId)) throw FeedNotFoundException(feedId);
    final list = _entries[feedId];
    var deleted = 0;
    var highestAcked = _acked[feedId] ?? -1;
    if (list != null) {
      final before = list.length;
      for (final e in list) {
        if (e.seq <= upTo && e.seq > highestAcked) highestAcked = e.seq;
      }
      list.removeWhere((e) => e.seq <= upTo);
      deleted = before - list.length;
    }
    // Clamp the watermark to the highest seq that actually existed at/below upTo,
    // never the raw upTo, so a read-capability holder can't ack MAX_SAFE_INTEGER
    // and brick the author — mirrors relay/src/feed_slot.ts so the fake matches.
    if (highestAcked > (_acked[feedId] ?? -1)) _acked[feedId] = highestAcked;
    return deleted;
  }

  /// Test helper: the ids of media blobs currently stored.
  Iterable<String> get mediaIds => _media.keys;

  /// Test helper mirroring the real relay's TTL sweep: destroy an undelivered
  /// entry WITHOUT advancing the acked watermark (sweeps don't ack).
  void sweepEntry(String feedId, int seq) {
    _entries[feedId]?.removeWhere((e) => e.seq == seq);
  }

  /// Test helper: a snapshot of a stored entry's ciphertext (what a wiretap of
  /// the relay would capture), for forward-secrecy assertions.
  List<int>? entryCiphertext(String feedId, int seq) {
    for (final e in _entries[feedId] ?? const <FeedEntry>[]) {
      if (e.seq == seq) return List.of(e.ciphertext);
    }
    return null;
  }

  @override
  Future<void> putMedia(String id, List<int> bytes) async => _media[id] = bytes;

  @override
  Future<List<int>?> getMedia(String id) async => _media[id];

  @override
  Future<void> deleteMedia(String id) async => _media.remove(id);
}
