import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gene/src/crypto/primitives.dart';
import 'package:gene/src/identity/identity_store.dart';
import 'package:gene/src/pairing/models.dart';

/// In-memory [FlutterSecureStorage] for tests — overrides only read/write so the
/// store works without the platform Keystore channel.
class _MemSecureStorage extends FlutterSecureStorage {
  _MemSecureStorage([Map<String, String>? seed]) : data = {...?seed};

  final Map<String, String> data;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }
}

const _seedKey = 'gene.identity.ed25519.seed';

void main() {
  test('first launch generates, persists, and reads back one identity',
      () async {
    final storage = _MemSecureStorage();
    final id = await IdentityStore(storage: storage).loadOrCreate();

    expect(id.publicKey, hasLength(32));
    expect(base64.decode(storage.data[_seedKey]!), hasLength(32));
    // A reload returns the SAME identity (the persisted seed is reused).
    final again = await IdentityStore(storage: storage).loadOrCreate();
    expect(again.publicKey, equals(id.publicKey));
  });

  test('a valid stored seed is loaded as-is, never re-minted', () async {
    final original = await LocalIdentity.generate();
    final seed = base64.encode(await Crypto.seedOf(original.keyPair));
    final storage = _MemSecureStorage({_seedKey: seed});

    final loaded = await IdentityStore(storage: storage).loadOrCreate();
    expect(loaded.publicKey, equals(original.publicKey));
    expect(storage.data[_seedKey], equals(seed),
        reason: 'a good seed must not be overwritten');
  });

  test('a structurally-corrupt seed is discarded and a fresh identity minted',
      () async {
    final storage = _MemSecureStorage({_seedKey: 'not%%%valid%%%base64'});
    final id = await IdentityStore(storage: storage).loadOrCreate();

    expect(id.publicKey, hasLength(32));
    expect(base64.decode(storage.data[_seedKey]!), hasLength(32),
        reason: 'corrupt seed replaced with a valid 32-byte one');
  });

  test('a decodable but wrong-length seed is discarded and re-minted', () async {
    final storage =
        _MemSecureStorage({_seedKey: base64.encode(List<int>.filled(16, 1))});
    final id = await IdentityStore(storage: storage).loadOrCreate();

    expect(id.publicKey, hasLength(32));
    expect(base64.decode(storage.data[_seedKey]!), hasLength(32));
  });
}
