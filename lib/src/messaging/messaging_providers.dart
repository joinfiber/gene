import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gene/src/messaging/message_store.dart';
import 'package:gene/src/messaging/messaging_service.dart';
import 'package:gene/src/messaging/models.dart';
import 'package:gene/src/pairing/models.dart';
import 'package:gene/src/pairing/pairing_providers.dart';

final messagingServiceProvider = Provider<MessagingService>(
  (ref) => MessagingService(ref.watch(relayTransportProvider)),
);

final messageStoreProvider = Provider<MessageStore>((ref) => MessageStore());

/// Where decrypted missive media is written (and re-resolved from on load),
/// created on first use. Shared by the sync path and the player so a missive's
/// relative [ReceivedMissive.fileName] always re-joins the live directory.
final missivesDirProvider = FutureProvider<Directory>((ref) async {
  final base = await ref.read(messageStoreProvider).directory();
  final dir = Directory('${base.path}/missives');
  if (!dir.existsSync()) await dir.create(recursive: true);
  return dir;
});

/// The local missive library (all received missives), loaded once and appended
/// to as syncs land. The conversation screen filters it by feed.
final libraryProvider =
    AsyncNotifierProvider<LibraryController, List<ReceivedMissive>>(
  LibraryController.new,
);

class LibraryController extends AsyncNotifier<List<ReceivedMissive>> {
  Future<void> _writes = Future.value();

  @override
  Future<List<ReceivedMissive>> build() =>
      ref.read(messageStoreProvider).load();

  /// Add [incoming], skipping any already present (by feed + seq), then persist.
  /// Serialized so two concurrent syncs can't clobber the stored file, and
  /// idempotent so a re-sync after a crash doesn't duplicate.
  Future<void> ingest(List<ReceivedMissive> incoming) {
    final existing = state.asData?.value ?? const <ReceivedMissive>[];
    final seen = {for (final m in existing) '${m.inboundFeedId}:${m.seq}'};
    final fresh = [
      for (final m in incoming)
        if (seen.add('${m.inboundFeedId}:${m.seq}')) m,
    ];
    if (fresh.isEmpty) return Future.value();
    return _commit([...existing, ...fresh]);
  }

  /// Publish immediately, then persist — writes serialized so concurrent
  /// ingests can't lose each other (a read-modify-write race on the stored blob).
  Future<void> _commit(List<ReceivedMissive> next) {
    state = AsyncData(next);
    final store = ref.read(messageStoreProvider);
    final write = _writes.then((_) => store.save(next));
    _writes = write.catchError((Object _) {});
    return write;
  }
}

/// Orchestrates a send or sync, keeping the service, the contact list (its
/// seq/cursor), and the library in step. Reads the *live* contact so it never
/// works from a stale snapshot, and on receive persists the library **before**
/// destroying the relay copy.
final conversationProvider = Provider<Conversation>(Conversation.new);

class Conversation {
  Conversation(this._ref);

  final Ref _ref;

  /// Sends are serialized through this chain. Two composes in flight at once
  /// would otherwise both read the same outbound seq, and the relay would reject
  /// the second as a duplicate — silently dropping that missive. Chaining makes
  /// each send read-and-advance the seq atomically with respect to the others.
  Future<void> _sends = Future.value();

  Future<void> send(
    Contact contact, {
    required String videoPath,
    required int durationMs,
  }) {
    final result = _sends.then(
      (_) => _send(contact, videoPath: videoPath, durationMs: durationMs),
    );
    // Keep the chain alive even if one send throws, so a single failure doesn't
    // wedge every later send.
    _sends = result.catchError((Object _) {});
    return result;
  }

  Future<void> _send(
    Contact contact, {
    required String videoPath,
    required int durationMs,
  }) async {
    final contacts = _ref.read(contactsProvider.notifier);
    final live = _live(contact.outboundFeedId) ?? contact;
    final seq = live.outboundSeq;
    await _ref.read(messagingServiceProvider).send(
          live,
          seq: seq,
          videoPath: videoPath,
          durationMs: durationMs,
        );
    // Advance past the seq we used, monotonically — never regress a value a
    // concurrent send may already have advanced. (Not reached if send threw,
    // so a failed send leaves the seq free to retry.)
    await contacts.mutate(
      live.outboundFeedId,
      (c) => c.outboundSeq > seq ? c : c.copyWith(outboundSeq: seq + 1),
    );
    // The missive is sealed and uploaded end-to-end; the local plaintext copy of
    // what we just sent has served its purpose. Drop it — best-effort, since a
    // lingering temp file is harmless, but leaving decrypted video on disk is
    // exactly the kind of thing this app shouldn't do.
    try {
      await File(videoPath).delete();
    } catch (_) {
      // best-effort cleanup
    }
  }

  /// Pull new missives for [contact]; returns how many arrived.
  Future<int> sync(Contact contact) async {
    final live = _live(contact.outboundFeedId) ?? contact;
    final dir = await _ref.read(missivesDirProvider.future);
    final result =
        await _ref.read(messagingServiceProvider).fetchNew(live, mediaDir: dir);
    if (result.received.isEmpty) return 0;
    // Persist the library FIRST — a crash here must never lose a missive we then
    // destroy on the relay. ingest is idempotent, so a re-sync is safe.
    await _ref.read(libraryProvider.notifier).ingest(result.received);
    // Only now destroy the relay copies and advance the cursor.
    await _ref.read(messagingServiceProvider).confirm(
          live,
          upTo: result.cursor,
          mediaIds: result.mediaIds,
        );
    await _ref
        .read(contactsProvider.notifier)
        .advanceInboundCursor(live.outboundFeedId, result.cursor);
    return result.received.length;
  }

  Contact? _live(String outboundFeedId) {
    final list = _ref.read(contactsProvider).asData?.value;
    if (list == null) return null;
    for (final c in list) {
      if (c.outboundFeedId == outboundFeedId) return c;
    }
    return null;
  }
}
