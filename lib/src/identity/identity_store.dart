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
      final seed = _decodeValidSeed(stored);
      if (seed != null) {
        // Rebuild OUTSIDE a catch: a 32-byte seed is always a valid Ed25519
        // seed, so a throw here is a transient/platform failure, not corruption.
        // Let it propagate (the next launch retries) rather than swallowing it
        // and overwriting a perfectly good identity — which would silently change
        // the safety number and orphan every existing relationship.
        final keyPair = await Crypto.signingKeyFromSeed(seed);
        return LocalIdentity(
          keyPair: keyPair,
          publicKey: await Crypto.publicKeyBytes(keyPair),
        );
      }
      // Only a structurally-corrupt seed (un-decodable or wrong length) reaches
      // here; discard it and mint fresh so the app still opens.
    }
    final identity = await LocalIdentity.generate();
    final seed = await Crypto.seedOf(identity.keyPair);
    await _storage.write(key: _seedKey, value: base64.encode(seed));
    // Read back before trusting the new identity, so the device never operates
    // under a seed that silently failed to persist (which would revert on the
    // next launch and change the safety number).
    final readback = await _storage.read(key: _seedKey);
    if (readback == null || _decodeValidSeed(readback) == null) {
      throw StateError('identity seed did not persist');
    }
    return identity;
  }

  /// Decode a stored seed, returning it only if it is a valid 32-byte Ed25519
  /// seed; `null` for structurally-corrupt input (so it can be re-minted).
  List<int>? _decodeValidSeed(String stored) {
    final List<int> bytes;
    try {
      bytes = base64.decode(stored);
    } on FormatException {
      return null;
    }
    return bytes.length == 32 ? bytes : null;
  }
}
