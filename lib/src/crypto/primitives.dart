import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Intention-revealing wrappers over `package:cryptography` for the primitives
/// gene's pairing and messaging use: Ed25519 signing, X25519 ECDH, SHA-256,
/// HKDF-SHA256, and XChaCha20-Poly1305 sealing. Pure Dart, so it runs in plain
/// unit tests.
///
/// (For production hardening, these calls could be backed by libsodium; the
/// surface here is deliberately small so that swap stays local.)
class Crypto {
  Crypto._();

  static final _ed25519 = Ed25519();
  static final _x25519 = X25519();
  static final _sha256 = Sha256();
  static final _aead = Xchacha20.poly1305Aead();
  static final _random = Random.secure();

  static List<int> randomBytes(int length) =>
      List<int>.generate(length, (_) => _random.nextInt(256));

  static Future<SimpleKeyPair> newSigningKey() => _ed25519.newKeyPair();
  static Future<SimpleKeyPair> newAgreementKey() => _x25519.newKeyPair();

  static Future<List<int>> publicKeyBytes(SimpleKeyPair keyPair) async =>
      (await keyPair.extractPublicKey()).bytes;

  /// The 32-byte private seed, for persistence; reconstruct with
  /// [signingKeyFromSeed].
  static Future<List<int>> seedOf(SimpleKeyPair keyPair) =>
      keyPair.extractPrivateKeyBytes();

  static Future<SimpleKeyPair> signingKeyFromSeed(List<int> seed) =>
      _ed25519.newKeyPairFromSeed(seed);

  static Future<List<int>> sign(
    List<int> message,
    SimpleKeyPair keyPair,
  ) async =>
      (await _ed25519.sign(message, keyPair: keyPair)).bytes;

  static Future<bool> verify(
    List<int> message,
    List<int> signature,
    List<int> publicKey,
  ) {
    return _ed25519.verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  }

  /// X25519 ECDH → raw shared-secret bytes. Rejects the all-zero output a
  /// low-order peer point would force (RFC 7748 §6.1), so a hostile ephemeral
  /// can't drive both sides to a predictable secret.
  static Future<List<int>> sharedSecret(
    SimpleKeyPair myKey,
    List<int> peerPublicKey,
  ) async {
    final secret = await _x25519.sharedSecretKey(
      keyPair: myKey,
      remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
    );
    final bytes = await secret.extractBytes();
    var accumulator = 0;
    for (final byte in bytes) {
      accumulator |= byte;
    }
    if (accumulator == 0) {
      throw StateError('X25519 produced an all-zero shared secret');
    }
    return bytes;
  }

  /// SHA-256 digest — the basis of the safety number.
  static Future<List<int>> digest(List<int> data) async =>
      (await _sha256.hash(data)).bytes;

  /// HKDF-SHA256 → a 32-byte key. [info] domain-separates the output; the
  /// optional [salt] (HKDF's extract salt) folds in extra entropy — e.g. the
  /// link secret, so the conversation key depends on the out-of-band secret and
  /// not the ECDH alone.
  static Future<List<int>> hkdf(
    List<int> secret,
    List<int> info, {
    List<int> salt = const <int>[],
  }) async {
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(secret),
      nonce: salt,
      info: info,
    );
    return key.extractBytes();
  }

  /// Seal [clearText] under a 32-byte [key]; output is `nonce‖ciphertext‖mac`.
  static Future<List<int>> seal(List<int> key, List<int> clearText) async {
    final box = await _aead.encrypt(clearText, secretKey: SecretKey(key));
    return box.concatenation();
  }

  /// Open bytes produced by [seal]; throws if authentication fails.
  static Future<List<int>> open(List<int> key, List<int> sealed) async {
    final box = SecretBox.fromConcatenation(
      sealed,
      nonceLength: _aead.nonceLength,
      macLength: _aead.macAlgorithm.macLength,
    );
    return _aead.decrypt(box, secretKey: SecretKey(key));
  }
}
