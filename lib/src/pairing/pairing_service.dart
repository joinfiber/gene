import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'package:gene/src/crypto/primitives.dart';
import 'package:gene/src/messaging/message_crypto.dart';
import 'package:gene/src/pairing/models.dart';
import 'package:gene/src/pairing/relay_transport.dart';

/// The single-use sealed pairing handshake (BACKEND.md §2), client side.
///
/// Inviter and redeemer each end up holding the other's identity key, a shared
/// conversation key `K`, an outbound feed (they author) and an inbound feed
/// (the peer authors) — having exchanged only one link over an untrusted
/// channel, with the relay seeing nothing but opaque ciphertext.
///
/// The handshake is *authenticated*: each side signs the key-exchange transcript
/// with its Ed25519 identity key, and the other verifies that signature before
/// deriving `K`. So the identity a peer records is *proven* (the peer
/// demonstrably holds the matching private key), which is what makes the
/// [Contact.safetyNumber] a meaningful MITM check rather than decoration. `K`
/// also folds in the link secret `S`, so it depends on the out-of-band secret
/// and not the ECDH alone.
class PairingService {
  PairingService._();

  /// Inviter: create the invite, returning the shareable [PendingPairing.link]
  /// and a handle to complete pairing once the peer redeems.
  ///
  /// [linkBase] is the human link prefix (e.g. `https://<relay-origin>/i/`) —
  /// the relay's own origin serves a landing page there, so a tapped link lands
  /// somewhere real. Only the trailing id and the `#fragment` secret are read
  /// back on redeem, so the host is cosmetic to the handshake.
  static Future<PendingPairing> mintInvite(
    LocalIdentity me,
    RelayTransport relay, {
    required String linkBase,
  }) async {
    final inviteId = Crypto.randomId();
    final linkSecret = Crypto.randomBytes(32);
    final ephemeral = await Crypto.newAgreementKey(); // per-invite X25519
    final ephemeralPublic = await Crypto.publicKeyBytes(ephemeral);
    final outboundFeedId = Crypto.randomId();
    final writeKey = await Crypto.newSigningKey(); // per-feed Ed25519

    final signature = await Crypto.sign(
      _inviteTranscript(inviteId, ephemeralPublic, me.publicKey),
      me.keyPair,
    );
    final payload = utf8.encode(
      jsonEncode({
        'id': base64.encode(me.publicKey),
        'ea': base64.encode(ephemeralPublic),
        'feed': outboundFeedId,
        'sig': base64.encode(signature),
      }),
    );
    final sealKey = await Crypto.hkdf(linkSecret, _inviteSealInfo);
    await relay.putInvite(inviteId, await Crypto.seal(sealKey, payload));

    return PendingPairing._(
      link: '$linkBase$inviteId#${base64Url.encode(linkSecret)}',
      inviteId: inviteId,
      linkSecret: linkSecret,
      me: me,
      ephemeral: ephemeral,
      outboundFeedId: outboundFeedId,
      writeKey: writeKey,
    );
  }

  /// Redeemer: open the invite, verify the inviter, claim it, and derive the
  /// relationship. Throws [PairingException] for any malformed or unauthentic
  /// input, and if the slot was already redeemed.
  static Future<Contact> redeemInvite(
    LocalIdentity me,
    String link,
    RelayTransport relay,
  ) async {
    final (inviteId, linkSecret) = _parseLink(link);

    final sealed = await relay.getInvite(inviteId);
    if (sealed == null) throw const PairingException('invite not found');
    final sealKey = await Crypto.hkdf(linkSecret, _inviteSealInfo);
    final Map<String, dynamic> invite;
    try {
      invite = jsonDecode(utf8.decode(await Crypto.open(sealKey, sealed)))
          as Map<String, dynamic>;
    } catch (_) {
      throw const PairingException('invite could not be opened — wrong or '
          'corrupt link');
    }
    final inviterPublicKey =
        _decodeKey(invite['id'], 'inviter identity key', _ed25519KeyBytes);
    final inviterEphemeral =
        _decodeKey(invite['ea'], 'inviter ephemeral key', _x25519KeyBytes);
    final inviterSignature = _decodeBytes(invite['sig'], 'inviter signature');
    final inboundFeedId = _requireFeedId(invite['feed']);

    // The inviter signed (inviteId, ea, inviterId): proves this ephemeral is
    // bound to the identity we're about to trust.
    final inviterAuthentic = await Crypto.verify(
      _inviteTranscript(inviteId, inviterEphemeral, inviterPublicKey),
      inviterSignature,
      inviterPublicKey,
    );
    if (!inviterAuthentic) {
      throw const PairingException('invite signature did not verify');
    }

    final ephemeral = await Crypto.newAgreementKey();
    final ephemeralPublic = await Crypto.publicKeyBytes(ephemeral);
    final z = await Crypto.sharedSecret(ephemeral, inviterEphemeral);

    final outboundFeedId = Crypto.randomId();
    final writeKey = await Crypto.newSigningKey();

    final signature = await Crypto.sign(
      _redeemTranscript(
        inviteId,
        inviterEphemeral,
        ephemeralPublic,
        inviterPublicKey,
        me.publicKey,
      ),
      me.keyPair,
    );
    final response = utf8.encode(
      jsonEncode({
        'id': base64.encode(me.publicKey),
        'feed': outboundFeedId,
        'sig': base64.encode(signature),
      }),
    );
    final responseKey = await Crypto.hkdf(z, _redeemSealInfo);
    // The ephemeral public key rides in the clear so the inviter can derive z.
    final body = <int>[
      ...ephemeralPublic,
      ...await Crypto.seal(responseKey, response),
    ];
    if (!await relay.redeemInvite(inviteId, body)) {
      throw const PairingException('invite already redeemed');
    }

    final k = await _conversationKey(
      z: z,
      linkSecret: linkSecret,
      inviteId: inviteId,
      inviterEphemeral: inviterEphemeral,
      redeemerEphemeral: ephemeralPublic,
      inviterId: inviterPublicKey,
      redeemerId: me.publicKey,
    );
    // Split K into the two per-feed ratchet roots and let K itself go out of
    // scope — only the (forward-advancing) chain state is ever persisted.
    return Contact(
      peerPublicKey: inviterPublicKey,
      outboundChainKey: await chainRoot(k, outboundFeedId),
      inboundChainKey: await chainRoot(k, inboundFeedId),
      outboundFeedId: outboundFeedId,
      outboundWriteKeySeed: await Crypto.seedOf(writeKey),
      inboundFeedId: inboundFeedId,
    );
  }
}

/// The inviter's side of an in-flight pairing: holds the secrets needed to
/// finish once the peer redeems.
class PendingPairing {
  PendingPairing._({
    required this.link,
    required this.inviteId,
    required this.outboundFeedId,
    required List<int> linkSecret,
    required LocalIdentity me,
    required SimpleKeyPair ephemeral,
    required SimpleKeyPair writeKey,
  })  : _linkSecret = linkSecret,
        _me = me,
        _ephemeral = ephemeral,
        _writeKey = writeKey;

  final String link;
  final String inviteId;
  final String outboundFeedId;
  final List<int> _linkSecret;
  final LocalIdentity _me;
  final SimpleKeyPair _ephemeral;
  final SimpleKeyPair _writeKey;

  /// Poll once for the peer's redemption: returns the [Contact] once paired, or
  /// null if the peer hasn't redeemed yet. Throws [PairingException] if the
  /// response is malformed or its signature does not verify.
  Future<Contact?> tryComplete(RelayTransport relay) async {
    final body = await relay.pollRedeem(inviteId);
    if (body == null) return null;
    if (body.length < _x25519KeyBytes + _sealOverheadBytes) {
      throw const PairingException('malformed redeem response');
    }

    final peerEphemeral = body.sublist(0, _x25519KeyBytes);
    final sealed = body.sublist(_x25519KeyBytes);
    final z = await Crypto.sharedSecret(_ephemeral, peerEphemeral);

    final responseKey = await Crypto.hkdf(z, _redeemSealInfo);
    final Map<String, dynamic> response;
    try {
      response = jsonDecode(utf8.decode(await Crypto.open(responseKey, sealed)))
          as Map<String, dynamic>;
    } catch (_) {
      throw const PairingException('redeem response could not be opened');
    }
    final peerPublicKey =
        _decodeKey(response['id'], 'peer identity key', _ed25519KeyBytes);
    final peerSignature = _decodeBytes(response['sig'], 'peer signature');
    final inboundFeedId = _requireFeedId(response['feed']);

    final myEphemeralPublic = await Crypto.publicKeyBytes(_ephemeral);
    final peerAuthentic = await Crypto.verify(
      _redeemTranscript(
        inviteId,
        myEphemeralPublic,
        peerEphemeral,
        _me.publicKey,
        peerPublicKey,
      ),
      peerSignature,
      peerPublicKey,
    );
    if (!peerAuthentic) {
      throw const PairingException('redeem signature did not verify');
    }

    final k = await _conversationKey(
      z: z,
      linkSecret: _linkSecret,
      inviteId: inviteId,
      inviterEphemeral: myEphemeralPublic,
      redeemerEphemeral: peerEphemeral,
      inviterId: _me.publicKey,
      redeemerId: peerPublicKey,
    );
    // As on the redeemer side: derive the two chain roots, never persist K.
    return Contact(
      peerPublicKey: peerPublicKey,
      outboundChainKey: await chainRoot(k, outboundFeedId),
      inboundChainKey: await chainRoot(k, inboundFeedId),
      outboundFeedId: outboundFeedId,
      outboundWriteKeySeed: await Crypto.seedOf(_writeKey),
      inboundFeedId: inboundFeedId,
    );
  }
}

/// Raised when a link, invite payload, or redeem response is malformed or fails
/// authentication — so callers get one clean failure type instead of a
/// `RangeError`, `FormatException`, or opaque AEAD throw.
class PairingException implements Exception {
  const PairingException(this.message);

  final String message;

  @override
  String toString() => 'PairingException: $message';
}

// --- wire constants & transcript binding -----------------------------------

const _x25519KeyBytes = 32;
const _ed25519KeyBytes = 32;

/// XChaCha20-Poly1305 framing overhead: a 24-byte nonce + a 16-byte tag. Used
/// only as a lower bound when validating an incoming sealed blob's length.
const _sealOverheadBytes = 24 + 16;

final _inviteSealInfo = utf8.encode('gene-invite');
final _redeemSealInfo = utf8.encode('gene-redeem');

/// Length-prefixed, domain-labelled concatenation — a canonical byte string so
/// that distinct field tuples never collide (no ambiguous boundaries).
List<int> _bind(String label, List<List<int>> parts) {
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

/// What the inviter signs at mint time (it doesn't yet know the redeemer's
/// ephemeral): binds its ephemeral to its identity, for this invite.
List<int> _inviteTranscript(
  String inviteId,
  List<int> inviterEphemeral,
  List<int> inviterId,
) =>
    _bind('gene-pair:invite', [
      utf8.encode(inviteId),
      inviterEphemeral,
      inviterId,
    ]);

/// What the redeemer signs: the full transcript — both ephemerals and both
/// identities — so the inviter can confirm the key exchange and the redeemer's
/// identity in one check.
List<int> _redeemTranscript(
  String inviteId,
  List<int> inviterEphemeral,
  List<int> redeemerEphemeral,
  List<int> inviterId,
  List<int> redeemerId,
) =>
    _bind('gene-pair:redeem', [
      utf8.encode(inviteId),
      inviterEphemeral,
      redeemerEphemeral,
      inviterId,
      redeemerId,
    ]);

/// The conversation key `K`, derived identically on both sides: HKDF over the
/// ECDH secret `z`, salted with the link secret `S`, bound to the full
/// transcript. Tampering with any exchanged value changes `K`, so the two sides
/// simply fail to communicate rather than silently talk through an attacker.
Future<List<int>> _conversationKey({
  required List<int> z,
  required List<int> linkSecret,
  required String inviteId,
  required List<int> inviterEphemeral,
  required List<int> redeemerEphemeral,
  required List<int> inviterId,
  required List<int> redeemerId,
}) {
  final info = _bind('gene-conv', [
    utf8.encode(inviteId),
    inviterEphemeral,
    redeemerEphemeral,
    inviterId,
    redeemerId,
  ]);
  return Crypto.hkdf(z, info, salt: linkSecret);
}

(String, List<int>) _parseLink(String link) {
  final Uri uri;
  try {
    uri = Uri.parse(link);
  } on FormatException {
    throw const PairingException('not a valid link');
  }
  final inviteId = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  if (inviteId.isEmpty) {
    throw const PairingException('link is missing its invite id');
  }
  if (uri.fragment.isEmpty) {
    throw const PairingException('link is missing its secret');
  }
  final List<int> secret;
  try {
    secret = base64Url.decode(uri.fragment);
  } on FormatException {
    throw const PairingException('link secret is malformed');
  }
  if (secret.length != 32) {
    throw const PairingException('link secret is the wrong length');
  }
  return (inviteId, secret);
}

List<int> _decodeBytes(Object? value, String what) {
  if (value is! String) throw PairingException('missing $what');
  try {
    return base64.decode(value);
  } on FormatException {
    throw PairingException('malformed $what');
  }
}

List<int> _decodeKey(Object? value, String what, int expectedLength) {
  final bytes = _decodeBytes(value, what);
  if (bytes.length != expectedLength) {
    throw PairingException('$what has the wrong length');
  }
  return bytes;
}

/// Feed ids are [Crypto.randomId] outputs: unpadded base64url. Validating the
/// alphabet keeps a peer-supplied id from carrying anything unexpected into the
/// ratchet's `chainRoot` derivation (message_crypto.dart) or the on-disk
/// `<feedId>-<seq>.mp4` file naming — structural, not by luck.
final _feedIdPattern = RegExp(r'^[A-Za-z0-9_-]+$');

String _requireFeedId(Object? value) {
  if (value is! String || value.isEmpty || !_feedIdPattern.hasMatch(value)) {
    throw const PairingException('missing or malformed feed id');
  }
  return value;
}
