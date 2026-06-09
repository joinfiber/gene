import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'package:gene/src/crypto/primitives.dart';
import 'package:gene/src/messaging/message_crypto.dart';
import 'package:gene/src/messaging/models.dart';
import 'package:gene/src/pairing/models.dart';
import 'package:gene/src/pairing/relay_transport.dart';

/// What a fetch pulled: the new missives (media already written to disk), the
/// cursor to advance to, and the media ids to destroy once the library is saved.
typedef FetchResult = ({
  List<ReceivedMissive> received,
  int cursor,
  List<String> mediaIds,
});

/// Sends and receives missives over a contact's two feeds (BACKEND.md §3–§4).
/// All crypto is client-side; the relay only moves opaque bytes.
///
/// Receiving is split into [fetchNew] (pull → decrypt → write to disk) and
/// [confirm] (ack → destroy) so the caller can persist the local library
/// *between* them — the relay copy is never destroyed before the device has
/// durably kept its own.
///
/// (Media is sealed in memory — fine for short missives; streaming AEAD is the
/// production upgrade for large video, noted but not built.)
class MessagingService {
  MessagingService(this._relay);

  final RelayTransport _relay;

  /// Encrypt [videoPath] under a fresh per-blob key, upload it, and append a
  /// sealed, signed entry at [seq] to the contact's outbound feed (creating the
  /// feed on first send). The caller chooses [seq]. A relay that already holds
  /// this seq (a retried send) is treated as success, and the freshly-uploaded
  /// blob is cleaned up on any failure so a retry can't strand it.
  Future<void> send(
    Contact contact, {
    required int seq,
    required String videoPath,
    required int durationMs,
  }) async {
    final mediaKey = Crypto.randomBytes(32);
    final mediaId = Crypto.randomId();
    var uploaded = false;
    try {
      final clear = await File(videoPath).readAsBytes();
      await _relay.putMedia(mediaId, await Crypto.seal(mediaKey, clear));
      uploaded = true;

      final missive =
          Missive(mediaId: mediaId, mediaKey: mediaKey, durationMs: durationMs);
      final subkey = await messageSubkey(
        contact.conversationKey,
        contact.outboundFeedId,
        seq,
      );
      final ciphertext =
          await Crypto.seal(subkey, utf8.encode(jsonEncode(missive.toJson())));
      final writeKey =
          await Crypto.signingKeyFromSeed(contact.outboundWriteKeySeed);
      final signature =
          await Crypto.sign(signedMessage(seq, ciphertext), writeKey);
      final entry =
          FeedEntry(seq: seq, signature: signature, ciphertext: ciphertext);
      await _appendCreatingIfNeeded(contact.outboundFeedId, entry, writeKey);
    } catch (e) {
      // Never strand the uploaded blob (an orphaned R2 object) on a failed send.
      if (uploaded) {
        try {
          await _relay.deleteMedia(mediaId);
        } catch (_) {
          // best-effort; the R2 lifecycle backstop catches the rest
        }
      }
      // The entry is already on the feed (a retried send) — treat as delivered.
      if (e is DuplicateSeqException) return;
      rethrow;
    }
  }

  Future<void> _appendCreatingIfNeeded(
    String feedId,
    FeedEntry entry,
    SimpleKeyPair writeKey,
  ) async {
    try {
      await _relay.appendEntry(feedId, entry);
    } on FeedNotFoundException {
      await _relay.createFeed(feedId, await Crypto.publicKeyBytes(writeKey));
      await _relay.appendEntry(feedId, entry);
    }
  }

  /// Pull entries newer than the contact's cursor, decrypt each, and write its
  /// media into [mediaDir]. **Stops** at the first entry it can't fully receive
  /// (a key mismatch, or media not yet available) rather than advancing past it,
  /// so nothing is acked or destroyed before it's been delivered. Does NOT ack
  /// or delete — call [confirm] once the library is persisted.
  Future<FetchResult> fetchNew(
    Contact contact, {
    required Directory mediaDir,
  }) async {
    final entries = await _relay.fetchEntries(
      contact.inboundFeedId,
      since: contact.inboundCursor,
    );
    final received = <ReceivedMissive>[];
    final mediaIds = <String>[];
    var cursor = contact.inboundCursor;

    for (final entry in entries) {
      final Missive missive;
      try {
        final subkey = await messageSubkey(
          contact.conversationKey,
          contact.inboundFeedId,
          entry.seq,
        );
        missive = Missive.fromJson(
          jsonDecode(utf8.decode(await Crypto.open(subkey, entry.ciphertext)))
              as Map<String, dynamic>,
        );
      } catch (_) {
        break; // entry won't open (key desync) — stop, don't advance past it
      }

      final sealedMedia = await _relay.getMedia(missive.mediaId);
      if (sealedMedia == null) break; // media not (yet) there — retry next sync

      final List<int> clear;
      try {
        clear = await Crypto.open(missive.mediaKey, sealedMedia);
      } catch (_) {
        break; // media won't decrypt — stop, don't burn the seq
      }

      final fileName = '${contact.inboundFeedId}-${entry.seq}.mp4';
      await File('${mediaDir.path}/$fileName').writeAsBytes(clear, flush: true);
      received.add(ReceivedMissive(
        inboundFeedId: contact.inboundFeedId,
        seq: entry.seq,
        fileName: fileName,
        durationMs: missive.durationMs,
        receivedAtMs: DateTime.now().millisecondsSinceEpoch,
      ));
      mediaIds.add(missive.mediaId);
      cursor = entry.seq; // entries are ascending → monotonic
    }

    return (received: received, cursor: cursor, mediaIds: mediaIds);
  }

  /// Destroy-after-delivery: ack delivered entries (`seq <= upTo`) and delete
  /// their media blobs. Call only after the local library is durably saved.
  Future<void> confirm(
    Contact contact, {
    required int upTo,
    required List<String> mediaIds,
  }) async {
    await _relay.ackEntries(contact.inboundFeedId, upTo);
    for (final id in mediaIds) {
      try {
        await _relay.deleteMedia(id);
      } catch (_) {
        // best-effort; the R2 lifecycle backstop catches the rest
      }
    }
  }
}
