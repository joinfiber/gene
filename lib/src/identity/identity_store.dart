import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:gene/src/crypto/primitives.dart';
import 'package:gene/src/pairing/models.dart';
import 'package:gene/src/storage/secure_storage.dart';

/// Persists the device's durable identity in platform secure storage
/// (Android Keystore-backed). Only the 32-byte Ed25519 seed is stored; the
/// keypair is rebuilt from it.
class IdentityStore {
  IdentityStore({FlutterSecureStorage? storage})
      : _storage = storage ?? geneSecureStorage;

  final FlutterSecureStorage _storage;
  static const _seedKey = 'gene.identity.ed25519.seed';

  /// Load the device identity, generating and persisting one on first launch.
  Future<LocalIdentity> loadOrCreate() async {
    final stored = await _storage.read(key: _seedKey);
    if (stored != null) {
      try {
        final keyPair = await Crypto.signingKeyFromSeed(base64.decode(stored));
        return LocalIdentity(
          keyPair: keyPair,
          publicKey: await Crypto.publicKeyBytes(keyPair),
        );
      } catch (_) {
        // A corrupt or wrong-length stored seed would otherwise throw on every
        // launch — a hard brick. Discard it and mint a fresh identity instead:
        // this changes the safety number (peers re-verify), but the app opens.
      }
    }
    final identity = await LocalIdentity.generate();
    await _storage.write(
      key: _seedKey,
      value: base64.encode(await Crypto.seedOf(identity.keyPair)),
    );
    return identity;
  }
}
