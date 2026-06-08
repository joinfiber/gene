import 'dart:convert';
import 'dart:typed_data';

import 'package:gene/src/crypto/primitives.dart';

/// Per-message crypto for feed entries (BACKEND.md §3–§4) — one source of truth
/// for the bytes an author signs and the subkey each entry is sealed under, so
/// sender, receiver, and relay all agree.

/// The exact bytes an author signs for a feed entry: an 8-byte big-endian [seq]
/// followed by the entry ciphertext — byte-for-byte identical to the relay's
/// `signedMessage`, so the relay's Ed25519 verification matches the client's
/// signature.
List<int> signedMessage(int seq, List<int> ciphertext) {
  final message = Uint8List(8 + ciphertext.length);
  ByteData.view(message.buffer).setUint64(0, seq, Endian.big);
  message.setRange(8, message.length, ciphertext);
  return message;
}

/// The per-message subkey that seals entry [seq] on [feedId]: `HKDF(K, dir‖seq)`
/// where the feed id is the direction — each direction is its own feed, so
/// sender and receiver derive the same key for the same entry, with no ratchet
/// state to synchronize (the right amount of machinery for low-cadence missives).
Future<List<int>> messageSubkey(
  List<int> conversationKey,
  String feedId,
  int seq,
) {
  final info = <int>[
    ...utf8.encode('gene-msg:$feedId:'),
    ..._u64be(seq),
  ];
  return Crypto.hkdf(conversationKey, info);
}

List<int> _u64be(int value) {
  final out = Uint8List(8);
  ByteData.view(out.buffer).setUint64(0, value, Endian.big);
  return out;
}
