import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'package:gene/src/crypto/primitives.dart';

/// The device's durable identity: an Ed25519 keypair whose public half is the
/// "who" a peer verifies. Generated on first launch; persisted to secure
/// storage (see `IdentityStore`).
class LocalIdentity {
  LocalIdentity({required this.keyPair, required this.publicKey});

  final SimpleKeyPair keyPair;
  final List<int> publicKey;

  static Future<LocalIdentity> generate() async {
    final keyPair = await Crypto.newSigningKey();
    return LocalIdentity(
      keyPair: keyPair,
      publicKey: await Crypto.publicKeyBytes(keyPair),
    );
  }
}

/// A paired relationship — everything needed to talk to one peer, held only on
/// this device. Pure data, so it serializes straight to secure storage. A
/// conversation is two unidirectional feeds: one we author, one the peer does,
/// plus the per-direction sequence bookkeeping that drives delivery.
class Contact {
  Contact({
    required this.peerPublicKey,
    required this.conversationKey,
    required this.outboundFeedId,
    required this.outboundWriteKeySeed,
    required this.inboundFeedId,
    this.name,
    this.outboundSeq = 1,
    this.inboundCursor = 0,
  });

  /// The peer's Ed25519 identity public key.
  final List<int> peerPublicKey;

  /// The shared conversation key `K` (32 bytes) — the root every message
  /// subkey is derived from.
  final List<int> conversationKey;

  /// The feed we author; sign entries with the key rebuilt from
  /// [outboundWriteKeySeed] (a per-feed key, never the identity key).
  final String outboundFeedId;
  final List<int> outboundWriteKeySeed;

  /// The feed we read — the peer authors it.
  final String inboundFeedId;

  /// User-assigned display name (set after pairing).
  final String? name;

  /// Next sequence number to use when we author on [outboundFeedId].
  final int outboundSeq;

  /// Highest sequence number we've received and acked on [inboundFeedId]; used
  /// as the `since` cursor when pulling.
  final int inboundCursor;

  /// A short, stable handle derived from the peer key, for display before the
  /// user names the contact. Not a security check — see [safetyNumber].
  String get shortId => base64Url.encode(peerPublicKey).substring(0, 8);

  /// A canonical, two-sided fingerprint over both identity keys — *identical*
  /// on both devices regardless of who invited whom (the keys are sorted first).
  /// Compared out-of-band ("read me your digits"), it upgrades TOFU pairing to
  /// verified and reveals a man-in-the-middle, who could only ever produce a
  /// different number. Eight groups of five digits (~133 bits).
  Future<String> safetyNumber(List<int> myPublicKey) async {
    final keys = [peerPublicKey, myPublicKey]..sort(_compareBytes);
    final material = await Crypto.digest(<int>[
      ...utf8.encode('gene-safety-number'),
      ...keys[0],
      ...keys[1],
    ]);
    final groups = <String>[];
    for (var i = 0; i < 8; i++) {
      final value = (material[i * 4] << 24) |
          (material[i * 4 + 1] << 16) |
          (material[i * 4 + 2] << 8) |
          material[i * 4 + 3];
      groups.add((value % 100000).toString().padLeft(5, '0'));
    }
    return groups.join(' ');
  }

  Contact copyWith({
    String? name,
    int? outboundSeq,
    int? inboundCursor,
  }) =>
      Contact(
        peerPublicKey: peerPublicKey,
        conversationKey: conversationKey,
        outboundFeedId: outboundFeedId,
        outboundWriteKeySeed: outboundWriteKeySeed,
        inboundFeedId: inboundFeedId,
        name: name ?? this.name,
        outboundSeq: outboundSeq ?? this.outboundSeq,
        inboundCursor: inboundCursor ?? this.inboundCursor,
      );

  Contact withName(String name) => copyWith(name: name);

  Map<String, dynamic> toJson() => {
        'peer': base64.encode(peerPublicKey),
        'k': base64.encode(conversationKey),
        'out': outboundFeedId,
        'seed': base64.encode(outboundWriteKeySeed),
        'in': inboundFeedId,
        'name': name,
        'seqOut': outboundSeq,
        'curIn': inboundCursor,
      };

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
        peerPublicKey: base64.decode(json['peer'] as String),
        conversationKey: base64.decode(json['k'] as String),
        outboundFeedId: json['out'] as String,
        outboundWriteKeySeed: base64.decode(json['seed'] as String),
        inboundFeedId: json['in'] as String,
        name: json['name'] as String?,
        outboundSeq: json['seqOut'] as int? ?? 1,
        inboundCursor: json['curIn'] as int? ?? 0,
      );
}

/// Lexicographic byte-order comparison, for canonically ordering two keys.
int _compareBytes(List<int> a, List<int> b) {
  final shared = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < shared; i++) {
    final difference = a[i] - b[i];
    if (difference != 0) return difference;
  }
  return a.length - b.length;
}
