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
///
/// **Forward secrecy:** the conversation key `K` from pairing is split into two
/// per-feed hash-ratchet chains (message_crypto.dart) and then discarded — it is
/// deliberately NOT stored here. What this record holds is only the *current*
/// chain state, from which past message keys cannot be re-derived.
class Contact {
  Contact({
    required this.peerPublicKey,
    required this.outboundChainKey,
    required this.inboundChainKey,
    required this.outboundFeedId,
    required this.outboundWriteKeySeed,
    required this.inboundFeedId,
    this.name,
    this.outboundSeq = 1,
    this.inboundCursor = 0,
    this.verified = false,
  });

  /// The peer's Ed25519 identity public key.
  final List<int> peerPublicKey;

  /// The outbound feed's chain key, positioned at [outboundSeq]: it derives the
  /// key that seals the *next* entry we author. Advanced (one-way) in the same
  /// mutation that advances [outboundSeq]; prior keys are gone.
  final List<int> outboundChainKey;

  /// The inbound feed's chain key, positioned at [inboundCursor] + 1: it derives
  /// the key for the next entry we expect to receive. Advanced in the same
  /// mutation that advances [inboundCursor]; prior keys are gone.
  final List<int> inboundChainKey;

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

  /// Whether the user has compared safety numbers out-of-band and confirmed they
  /// match — the TOFU→verified upgrade, recorded so the UI can show it.
  final bool verified;

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
    // Treat the 256-bit digest as one big integer and peel off 5-digit groups by
    // repeated mod/div. This consumes the whole digest with bias (2^256 mod
    // 100000^8) that is astronomically small, instead of a per-4-byte
    // `value % 100000` that leaves a ~1.6e-5 modulo bias in every group.
    var acc = BigInt.zero;
    for (final byte in material) {
      acc = (acc << 8) | BigInt.from(byte);
    }
    final mod = BigInt.from(100000);
    final groups = <String>[];
    for (var i = 0; i < 8; i++) {
      groups.add((acc % mod).toInt().toString().padLeft(5, '0'));
      acc = acc ~/ mod;
    }
    return groups.join(' ');
  }

  Contact copyWith({
    String? name,
    int? outboundSeq,
    int? inboundCursor,
    List<int>? outboundChainKey,
    List<int>? inboundChainKey,
    bool? verified,
  }) =>
      Contact(
        peerPublicKey: peerPublicKey,
        outboundChainKey: outboundChainKey ?? this.outboundChainKey,
        inboundChainKey: inboundChainKey ?? this.inboundChainKey,
        outboundFeedId: outboundFeedId,
        outboundWriteKeySeed: outboundWriteKeySeed,
        inboundFeedId: inboundFeedId,
        name: name ?? this.name,
        outboundSeq: outboundSeq ?? this.outboundSeq,
        inboundCursor: inboundCursor ?? this.inboundCursor,
        verified: verified ?? this.verified,
      );

  Contact withName(String name) => copyWith(name: name);

  Map<String, dynamic> toJson() => {
        'peer': base64.encode(peerPublicKey),
        'cko': base64.encode(outboundChainKey),
        'cki': base64.encode(inboundChainKey),
        'out': outboundFeedId,
        'seed': base64.encode(outboundWriteKeySeed),
        'in': inboundFeedId,
        'name': name,
        'seqOut': outboundSeq,
        'curIn': inboundCursor,
        'v': verified,
      };

  /// Whether [json] is the legacy (v1) shape that stored the conversation key
  /// `K` directly — migrated (chains derived, `K` purged) by `ContactStore`.
  static bool isLegacyJson(Map<String, dynamic> json) => json.containsKey('k');

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
        peerPublicKey: base64.decode(json['peer'] as String),
        outboundChainKey: base64.decode(json['cko'] as String),
        inboundChainKey: base64.decode(json['cki'] as String),
        outboundFeedId: json['out'] as String,
        outboundWriteKeySeed: base64.decode(json['seed'] as String),
        inboundFeedId: json['in'] as String,
        name: json['name'] as String?,
        outboundSeq: json['seqOut'] as int? ?? 1,
        inboundCursor: json['curIn'] as int? ?? 0,
        verified: json['v'] as bool? ?? false,
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
