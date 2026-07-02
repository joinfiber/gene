import 'dart:convert';
import 'dart:typed_data';

import 'package:gene/src/crypto/primitives.dart';

/// Per-message crypto for feed entries (BACKEND.md §3–§4) — one source of truth
/// for the bytes an author signs and the per-message keys each entry is sealed
/// under.
///
/// Of this file, only [signedMessage] crosses the relay boundary (it must stay
/// byte-compatible with `relay/src/codec.ts`). Everything else is client-only:
/// the relay never derives a key or opens anything.
///
/// ## Forward secrecy: the per-feed hash ratchet
///
/// Each feed (one direction of a conversation) carries a **chain key**. The key
/// that seals entry `seq` is `messageKey(CK_seq)`, and the chain advances as
/// `CK_{seq+1} = nextChainKey(CK_seq)` — a one-way HKDF step. Both sides derive
/// the same chain from the conversation key `K` at pairing time
/// ([chainRoot]), after which **`K` itself is discarded** and consumed chain
/// keys are deleted as each side advances.
///
/// Because the steps are one-way, state held at position `p` cannot re-derive
/// any key for `seq < p`: compromise a device today and yesterday's
/// (delivered-and-destroyed) missives stay sealed even if their ciphertext was
/// captured in transit. That is forward secrecy. It is **not** post-compromise
/// security — today's state does derive all *future* keys until re-pairing; a
/// DH ratchet is that upgrade (see SECURITY.md).
///
/// There is no ratchet *synchronization* cost: the chain position is simply the
/// entry seq, which already travels with every entry.

/// The exact bytes an author signs for a feed entry: an 8-byte big-endian [seq]
/// followed by the entry ciphertext — byte-for-byte identical to the relay's
/// `signedMessage`, so the relay's Ed25519 verification matches the client's
/// signature.
List<int> signedMessage(int seq, List<int> ciphertext) {
  final message = Uint8List(8 + ciphertext.length);
  _writeU64be(ByteData.view(message.buffer), 0, seq);
  message.setRange(8, message.length, ciphertext);
  return message;
}

/// The chain key for a feed's **first** entry (seq 1), derived from the
/// conversation key `K` and bound to the feed id with a length-prefixed,
/// domain-labelled encoding (no delimiter ambiguity, whatever the id alphabet).
/// Derive one per feed at pairing time, then discard `K`.
Future<List<int>> chainRoot(List<int> conversationKey, String feedId) =>
    Crypto.hkdf(conversationKey, _bindContext('gene-chain-root', [
      utf8.encode(feedId),
    ]));

/// One one-way ratchet step: the chain key for `seq + 1` from the chain key for
/// `seq`. The old key should be discarded after use — that deletion is what
/// makes the ratchet forward-secure.
Future<List<int>> nextChainKey(List<int> chainKey) =>
    Crypto.hkdf(chainKey, _chainStepInfo);

/// The key that seals the entry at the chain's current position. Domain-
/// separated from [nextChainKey] so a message key never doubles as chain state.
Future<List<int>> messageKey(List<int> chainKey) =>
    Crypto.hkdf(chainKey, _messageKeyInfo);

/// Advance [chainKey] forward by [steps] (≥ 0) one-way steps. Used by a reader
/// to fast-forward over entries the relay's TTL sweep destroyed before they
/// were collected — their keys are consumed and discarded, unrecoverable, which
/// is the correct forward-secrecy behavior for content that no longer exists.
Future<List<int>> fastForwardChain(List<int> chainKey, int steps) async {
  var ck = chainKey;
  for (var i = 0; i < steps; i++) {
    ck = await nextChainKey(ck);
  }
  return ck;
}

/// Ceiling on how far a reader will fast-forward in one fetch. Entries are
/// authored one at a time, so a legitimate gap (a TTL sweep) is at most the
/// author's real send count; a relay presenting a absurd seq jump is refused
/// rather than being allowed to spin the CPU deriving 2^50 keys.
const int maxChainSkip = 4096;

/// Sealed entries are padded to this bucket before encryption, so the entry
/// ciphertext length stops leaking the payload's shape (BACKEND.md §5 —
/// "pad entries to fixed buckets"). Every current missive fits one bucket;
/// larger payloads simply aren't padded (never truncated).
const int entryPadBucket = 512;

/// Pad UTF-8 JSON [payload] with trailing spaces (valid JSON whitespace, so
/// `jsonDecode` on the opened plaintext is unaffected) up to [entryPadBucket].
List<int> padEntryPayload(List<int> payload) {
  if (payload.length >= entryPadBucket) return payload;
  return [
    ...payload,
    ...List<int>.filled(entryPadBucket - payload.length, 0x20),
  ];
}

final _chainStepInfo = utf8.encode('gene-chain-step');
final _messageKeyInfo = utf8.encode('gene-message-key');

/// Length-prefixed, domain-labelled concatenation — a canonical byte string so
/// distinct field tuples never collide (mirrors pairing's transcript binding).
List<int> _bindContext(String label, List<List<int>> parts) {
  final out = <int>[...utf8.encode(label)];
  for (final part in parts) {
    out
      ..addAll(_u32be(part.length))
      ..addAll(part);
  }
  return out;
}

List<int> _u32be(int value) => [
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ];

/// Write [value] as a big-endian unsigned 64-bit integer at [offset], using two
/// 32-bit writes rather than `setUint64`. The bytes are identical, but this also
/// works on the dart2js/web backend, where 64-bit `ByteData` ops are unsupported
/// — so the portable core stays portable if it is ever compiled for web.
void _writeU64be(ByteData view, int offset, int value) {
  view.setUint32(offset, (value ~/ 0x100000000) & 0xFFFFFFFF, Endian.big);
  view.setUint32(offset + 4, value & 0xFFFFFFFF, Endian.big);
}
