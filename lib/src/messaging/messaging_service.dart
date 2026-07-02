import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'package:gene/src/crypto/primitives.dart';
import 'package:gene/src/messaging/message_crypto.dart';
import 'package:gene/src/messaging/models.dart';
import 'package:gene/src/pairing/models.dart';
import 'package:gene/src/pairing/relay_transport.dart';

/// What a fetch pulled: the new missives (media already written to disk), the
/// cursor to advance to, the inbound chain key positioned at `cursor + 1`
/// (persist it together with the cursor — they are one piece of state), and the
/// media ids to destroy once the library is saved.
typedef FetchResult = ({
  List<ReceivedMissive> received,
  int cursor,
  List<int> inboundChainKey,
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
  /// feed on first send). The caller chooses [seq], which must be at or ahead of
  /// the contact's `outboundSeq` (where its chain key is positioned): the entry
  /// key is derived by fast-forwarding the chain to [seq] — forward-only, so a
  /// retry with the same, un-advanced contact re-derives the same key, and a
  /// seq *behind* the chain is underivable by construction (its key is gone).
  /// A relay that already holds this seq (a retried send, pending or already
  /// acked) is treated as success, and the freshly-uploaded blob is cleaned up
  /// on any failure so a retry can't strand it.
  Future<void> send(
    Contact contact, {
    required int seq,
    required String videoPath,
    required int durationMs,
  }) async {
    final steps = seq - contact.outboundSeq;
    if (steps < 0 || steps > maxChainSkip) {
      throw ArgumentError.value(
        seq,
        'seq',
        'must be within [outboundSeq, outboundSeq + $maxChainSkip] — keys '
            'behind the chain position are deliberately underivable',
      );
    }
    final mediaKey = Crypto.randomBytes(32);
    final mediaId = Crypto.randomId();
    var uploaded = false;
    try {
      final clear = await File(videoPath).readAsBytes();
      await _relay.putMedia(mediaId, await Crypto.seal(mediaKey, clear));
      uploaded = true;

      final missive =
          Missive(mediaId: mediaId, mediaKey: mediaKey, durationMs: durationMs);
      final entryKey = await messageKey(
        await fastForwardChain(contact.outboundChainKey, steps),
      );
      final ciphertext = await Crypto.seal(
        entryKey,
        padEntryPayload(utf8.encode(jsonEncode(missive.toJson()))),
      );
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
      // A retried send whose original actually landed: the entry is either still
      // pending (DuplicateSeq) or already delivered-and-acked past the watermark
      // (StaleSeq). Both mean "this seq was delivered" — treat as success so the
      // caller advances past it, rather than rethrowing StaleSeq forever and
      // permanently wedging the feed at a seq the relay will never accept again.
      if (e is DuplicateSeqException || e is StaleSeqException) return;
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

  /// Pull entries newer than the contact's cursor, decrypt each (walking the
  /// inbound ratchet), and write its media into [mediaDir]. **Stops** at the
  /// first entry it can't fully receive (a key mismatch, or media not yet
  /// available) rather than advancing past it, so nothing is acked or destroyed
  /// before it's been delivered — and the returned chain state always
  /// corresponds to the returned cursor, so a crash before persisting simply
  /// re-derives the same keys next sync. Does NOT ack or delete — call
  /// [confirm] once the library is persisted.
  ///
  /// A seq missing from the relay's response (destroyed by the TTL sweep before
  /// it was collected) is fast-forwarded over: its key is consumed and discarded,
  /// permanently — correct forward secrecy for content that no longer exists.
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
    // The chain key positioned at cursor + 1 — the committed state we return.
    var chainKey = contact.inboundChainKey;

    for (final entry in entries) {
      // Entries arrive ascending with seq > cursor, so steps is >= 0; a gap
      // (TTL-swept seqs) fast-forwards. Refuse an absurd jump rather than let a
      // hostile relay spin the CPU deriving keys.
      final steps = entry.seq - (cursor + 1);
      if (steps < 0 || steps > maxChainSkip) break;

      final Missive missive;
      final List<int> chainKeyAtEntry;
      try {
        chainKeyAtEntry = await fastForwardChain(chainKey, steps);
        final entryKey = await messageKey(chainKeyAtEntry);
        missive = Missive.fromJson(
          jsonDecode(utf8.decode(await Crypto.open(entryKey, entry.ciphertext)))
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
      // Commit: cursor and chain advance together (chain to entry.seq + 1).
      cursor = entry.seq;
      chainKey = await nextChainKey(chainKeyAtEntry);
    }

    return (
      received: received,
      cursor: cursor,
      inboundChainKey: chainKey,
      mediaIds: mediaIds,
    );
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
