import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gene/src/crypto/primitives.dart';
import 'package:gene/src/identity/identity_store.dart';
import 'package:gene/src/pairing/models.dart';

import 'support/mem_secure_storage.dart';

const _seedKey = 'gene.identity.ed25519.seed';

void main() {
  test('first launch generates, persists, and reads back one identity',
      () async {
    final storage = MemSecureStorage();
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
    final storage = MemSecureStorage({_seedKey: seed});

    final loaded = await IdentityStore(storage: storage).loadOrCreate();
    expect(loaded.publicKey, equals(original.publicKey));
    expect(storage.data[_seedKey], equals(seed),
        reason: 'a good seed must not be overwritten');
  });

  test('a structurally-corrupt seed is discarded and a fresh identity minted',
      () async {
    final storage = MemSecureStorage({_seedKey: 'not%%%valid%%%base64'});
    final id = await IdentityStore(storage: storage).loadOrCreate();

    expect(id.publicKey, hasLength(32));
    expect(base64.decode(storage.data[_seedKey]!), hasLength(32),
        reason: 'corrupt seed replaced with a valid 32-byte one');
  });

  test('a decodable but wrong-length seed is discarded and re-minted', () async {
    final storage =
        MemSecureStorage({_seedKey: base64.encode(List<int>.filled(16, 1))});
    final id = await IdentityStore(storage: storage).loadOrCreate();

    expect(id.publicKey, hasLength(32));
    expect(base64.decode(storage.data[_seedKey]!), hasLength(32));
  });
}
