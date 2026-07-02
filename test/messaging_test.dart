import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gene/src/crypto/primitives.dart';
import 'package:gene/src/messaging/message_crypto.dart';
import 'package:gene/src/messaging/message_store.dart';
import 'package:gene/src/messaging/messaging_providers.dart';
import 'package:gene/src/messaging/messaging_service.dart';
import 'package:gene/src/messaging/models.dart';
import 'package:gene/src/pairing/contact_store.dart';
import 'package:gene/src/pairing/models.dart';
import 'package:gene/src/pairing/pairing_providers.dart';
import 'package:gene/src/pairing/pairing_service.dart';
import 'package:gene/src/pairing/relay_transport.dart';

import 'support/mem_secure_storage.dart';

const _linkBase = 'https://relay.test/i/';

/// Pairs two fresh identities over an in-memory relay and returns both contacts.
Future<({Contact alice, Contact bob, InMemoryRelay relay})> _pair() async {
  final relay = InMemoryRelay();
  final a = await LocalIdentity.generate();
  final b = await LocalIdentity.generate();
  final pending = await PairingService.mintInvite(a, relay, linkBase: _linkBase);
  final bob = await PairingService.redeemInvite(b, pending.link, relay);
  final alice = (await pending.tryComplete(relay))!;
  return (alice: alice, bob: bob, relay: relay);
}

File _fakeVideo(Directory dir, List<int> bytes) =>
    File('${dir.path}/take.mp4')..writeAsBytesSync(bytes);

File _fakeVideoNamed(Directory dir, String name, List<int> bytes) =>
    File('${dir.path}/$name')..writeAsBytesSync(bytes);

/// An in-memory [ContactStore] for tests — overrides load/save so the contacts
/// provider works without the platform secure-storage channel.
class _MemContactStore extends ContactStore {
  _MemContactStore([List<Contact>? seed]) : _contacts = [...?seed];

  final List<Contact> _contacts;

  @override
  Future<List<Contact>> load() async => List.of(_contacts);

  @override
  Future<void> save(List<Contact> contacts) async {
    _contacts
      ..clear()
      ..addAll(contacts);
  }
}

void main() {
  test('a missive sent by Alice is received and decrypted by Bob, then '
      'destroyed on the relay', () async {
    final p = await _pair();
    final service = MessagingService(p.relay);

    final tmp = await Directory.systemTemp.createTemp('gene_send');
    final original = List<int>.generate(5000, (i) => (i * 7 + 3) % 256);
    final video = _fakeVideo(tmp, original);

    await service.send(p.alice,
        seq: p.alice.outboundSeq, videoPath: video.path, durationMs: 4200);

    final inbox = await Directory.systemTemp.createTemp('gene_inbox');
    final r = await service.fetchNew(p.bob, mediaDir: inbox);

    expect(r.received, hasLength(1));
    final got = r.received.single;
    expect(got.durationMs, 4200);
    expect(got.inboundFeedId, p.bob.inboundFeedId);
    expect(got.seq, 1);
    expect(
      File('${inbox.path}/${got.fileName}').readAsBytesSync(),
      equals(original),
      reason: 'the media round-trips through encrypt → relay → decrypt',
    );
    expect(r.cursor, 1);

    // Destroy-after-delivery: confirm, then nothing is left to fetch.
    await service.confirm(p.bob, upTo: r.cursor, mediaIds: r.mediaIds);
    final again = await service.fetchNew(
      p.bob.copyWith(inboundCursor: r.cursor),
      mediaDir: inbox,
    );
    expect(again.received, isEmpty);

    tmp.deleteSync(recursive: true);
    inbox.deleteSync(recursive: true);
  });

  test('a wrong conversation key reads nothing and does not advance the cursor',
      () async {
    final p = await _pair();
    final service = MessagingService(p.relay);
    final tmp = await Directory.systemTemp.createTemp('gene_send2');
    await service.send(p.alice,
        seq: 1,
        videoPath: _fakeVideo(tmp, List<int>.filled(1000, 9)).path,
        durationMs: 1000);

    final tampered = Contact(
      peerPublicKey: p.bob.peerPublicKey,
      outboundChainKey: Crypto.randomBytes(32), // wrong ratchet state
      inboundChainKey: Crypto.randomBytes(32),
      outboundFeedId: p.bob.outboundFeedId,
      outboundWriteKeySeed: p.bob.outboundWriteKeySeed,
      inboundFeedId: p.bob.inboundFeedId,
    );
    final inbox = await Directory.systemTemp.createTemp('gene_inbox2');
    final r = await service.fetchNew(tampered, mediaDir: inbox);
    expect(r.received, isEmpty);
    expect(r.cursor, 0, reason: 'cursor must not advance');

    tmp.deleteSync(recursive: true);
    inbox.deleteSync(recursive: true);
  });

  test('re-sending the same seq is treated as already delivered (no wedge)',
      () async {
    final p = await _pair();
    final service = MessagingService(p.relay);
    final tmp = await Directory.systemTemp.createTemp('gene_dup');
    final path = _fakeVideo(tmp, List<int>.filled(500, 1)).path;

    await service.send(p.alice, seq: 1, videoPath: path, durationMs: 100);
    // A retried send at the same seq (e.g. a lost append response) must not
    // throw — the entry is already delivered.
    await service.send(p.alice, seq: 1, videoPath: path, durationMs: 100);

    final inbox = await Directory.systemTemp.createTemp('gene_dup_in');
    final r = await service.fetchNew(p.bob, mediaDir: inbox);
    expect(r.received, hasLength(1), reason: 'still exactly one missive');

    tmp.deleteSync(recursive: true);
    inbox.deleteSync(recursive: true);
  });

  test('fetchNew stops at the first entry whose media is gone — it does not '
      'skip the gap to deliver a later one', () async {
    final p = await _pair();
    final service = MessagingService(p.relay);
    final tmp = await Directory.systemTemp.createTemp('gene_mm');

    await service.send(p.alice,
        seq: 1,
        videoPath: _fakeVideoNamed(tmp, 'v1.mp4', List<int>.filled(400, 1)).path,
        durationMs: 100);
    // Snapshot seq 1's media id before sending seq 2, so we can delete *only* it.
    final firstBlobs = p.relay.mediaIds.toSet();
    await service.send(p.alice,
        seq: 2,
        videoPath: _fakeVideoNamed(tmp, 'v2.mp4', List<int>.filled(400, 2)).path,
        durationMs: 200);

    // Seq 1's blob is swept; seq 2's is still present.
    for (final id in firstBlobs) {
      await p.relay.deleteMedia(id);
    }

    final inbox = await Directory.systemTemp.createTemp('gene_mm_in');
    final r = await service.fetchNew(p.bob, mediaDir: inbox);
    // Must stop at the seq-1 gap, NOT skip ahead to deliver seq 2.
    expect(r.received, isEmpty);
    expect(r.cursor, 0, reason: 'cursor must not advance past the gap');

    tmp.deleteSync(recursive: true);
    inbox.deleteSync(recursive: true);
  });

  test('a retried send of an already-delivered-and-acked seq is treated as '
      'delivered, not a permanent wedge', () async {
    final p = await _pair();
    final service = MessagingService(p.relay);
    final tmp = await Directory.systemTemp.createTemp('gene_stale');
    final path = _fakeVideoNamed(tmp, 's.mp4', List<int>.filled(300, 5)).path;

    // Alice sends seq 1; Bob receives and acks it, advancing the relay watermark.
    await service.send(p.alice, seq: 1, videoPath: path, durationMs: 100);
    final inbox = await Directory.systemTemp.createTemp('gene_stale_in');
    final r = await service.fetchNew(p.bob, mediaDir: inbox);
    await service.confirm(p.bob, upTo: r.cursor, mediaIds: r.mediaIds);

    // A retried send at the now-acked seq 1 returns StaleSeq from the relay. It
    // must be treated as "already delivered" (no throw), or the feed wedges
    // forever at a seq the relay will never accept again.
    await expectLater(
      service.send(p.alice, seq: 1, videoPath: path, durationMs: 100),
      completes,
    );

    tmp.deleteSync(recursive: true);
    inbox.deleteSync(recursive: true);
  });

  test('the in-memory relay clamps the ack watermark — a later legit seq still '
      'appends after an over-ack', () async {
    final p = await _pair();
    final service = MessagingService(p.relay);
    final tmp = await Directory.systemTemp.createTemp('gene_clamp');

    await service.send(p.alice,
        seq: 1,
        videoPath: _fakeVideoNamed(tmp, 'c1.mp4', const [1, 2, 3]).path,
        durationMs: 1);
    // A read-capability holder acks far past anything stored, trying to push the
    // watermark to a huge value and brick the author.
    await p.relay.ackEntries(p.alice.outboundFeedId, 1 << 50);
    // The author's next legitimate seq must still be accepted (watermark clamped
    // to the highest stored seq, 1 — not the raw upTo), and reach Bob.
    await service.send(p.alice,
        seq: 2,
        videoPath: _fakeVideoNamed(tmp, 'c2.mp4', const [4, 5, 6]).path,
        durationMs: 1);

    final inbox = await Directory.systemTemp.createTemp('gene_clamp_in');
    final r = await service.fetchNew(p.bob, mediaDir: inbox);
    expect(r.received.map((m) => m.seq), [2],
        reason: 'seq 2 delivered after the over-ack (watermark was clamped)');

    tmp.deleteSync(recursive: true);
    inbox.deleteSync(recursive: true);
  });

  test('the library ingests idempotently — a re-sync does not duplicate',
      () async {
    final tmp = await Directory.systemTemp.createTemp('gene_libstore');
    final container = ProviderContainer(overrides: [
      messageStoreProvider.overrideWithValue(MessageStore(directory: tmp)),
    ]);
    addTearDown(container.dispose);
    addTearDown(() => tmp.deleteSync(recursive: true));

    await container.read(libraryProvider.future);
    final m = ReceivedMissive(
      inboundFeedId: 'feed',
      seq: 1,
      fileName: 'feed-1.mp4',
      durationMs: 0,
      receivedAtMs: 0,
    );
    final lib = container.read(libraryProvider.notifier);
    await lib.ingest([m]);
    await lib.ingest([m]); // same (feed, seq) again
    expect(container.read(libraryProvider).asData?.value, hasLength(1));
  });

  test('concurrent sends get distinct seqs — neither missive is dropped',
      () async {
    final p = await _pair();
    final tmp = await Directory.systemTemp.createTemp('gene_concurrent');
    final a = _fakeVideoNamed(tmp, 'a.mp4', List<int>.filled(300, 1));
    final b = _fakeVideoNamed(tmp, 'b.mp4', List<int>.filled(300, 2));

    final container = ProviderContainer(overrides: [
      relayTransportProvider.overrideWithValue(p.relay),
      contactStoreProvider.overrideWithValue(_MemContactStore([p.alice])),
    ]);
    addTearDown(container.dispose);
    addTearDown(() => tmp.deleteSync(recursive: true));

    await container.read(contactsProvider.future); // load the seeded contact
    final conversation = container.read(conversationProvider);

    // Fire two sends at once. Without serialization both read outboundSeq=1, and
    // the relay rejects the second as a duplicate — losing that missive.
    await Future.wait([
      conversation.send(p.alice, videoPath: a.path, durationMs: 100),
      conversation.send(p.alice, videoPath: b.path, durationMs: 200),
    ]);

    final inbox = await Directory.systemTemp.createTemp('gene_concurrent_in');
    addTearDown(() => inbox.deleteSync(recursive: true));
    final r = await MessagingService(p.relay).fetchNew(p.bob, mediaDir: inbox);
    expect(r.received, hasLength(2), reason: 'no missive was dropped');
    expect(r.received.map((m) => m.seq).toSet(), {1, 2});

    // The contact's outbound seq advanced past both sends.
    final live = container
        .read(contactsProvider)
        .asData!
        .value
        .firstWhere((c) => c.outboundFeedId == p.alice.outboundFeedId);
    expect(live.outboundSeq, 3);

    // The local plaintext copies were cleaned up after sending.
    expect(a.existsSync(), isFalse);
    expect(b.existsSync(), isFalse);
  });

  test('Crypto.randomId is url-safe, unpadded, and collision-free', () {
    final id = Crypto.randomId();
    expect(id, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    expect(id, isNot(contains('=')));
    expect(id.length, 22,
        reason: '16 bytes of entropy = 22 unpadded base64url chars');
    final ids = {for (var i = 0; i < 1000; i++) Crypto.randomId()};
    expect(ids, hasLength(1000), reason: '128-bit ids do not collide');
  });

  test('InMemoryRelay pins the feed author key write-once (no silent re-bind)',
      () async {
    final relay = InMemoryRelay();
    final k1 = await Crypto.newSigningKey();
    final k2 = await Crypto.newSigningKey();
    await relay.createFeed('f', await Crypto.publicKeyBytes(k1));
    await relay.createFeed('f', await Crypto.publicKeyBytes(k2)); // must no-op

    const ct = [1, 2, 3];
    // An entry signed by the ORIGINAL key still verifies (key was not re-bound).
    await relay.appendEntry(
      'f',
      FeedEntry(
        seq: 1,
        signature: await Crypto.sign(signedMessage(1, ct), k1),
        ciphertext: ct,
      ),
    );
    // One signed by the second key must NOT verify (still bound to k1).
    await expectLater(
      relay.appendEntry(
        'f',
        FeedEntry(
          seq: 2,
          signature: await Crypto.sign(signedMessage(2, ct), k2),
          ciphertext: ct,
        ),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('signedMessage is big-endian seq ‖ ciphertext', () {
    expect(
      signedMessage(1, [0xAA, 0xBB]),
      [0, 0, 0, 0, 0, 0, 0, 1, 0xAA, 0xBB],
    );
    expect(signedMessage(258, const <int>[]), [0, 0, 0, 0, 0, 0, 1, 2]);
  });

  test('the ratchet chain is deterministic, feed-bound, and domain-separated',
      () async {
    final k = Crypto.randomBytes(32);
    // Deterministic: both sides derive the same root and steps.
    expect(await chainRoot(k, 'feed'), equals(await chainRoot(k, 'feed')));
    // Bound to the feed: different feeds → unrelated chains.
    expect(await chainRoot(k, 'feedA'),
        isNot(equals(await chainRoot(k, 'feedB'))));
    final ck = await chainRoot(k, 'feed');
    // Message key and next chain key are domain-separated from each other and
    // from the chain key itself.
    expect(await messageKey(ck), isNot(equals(await nextChainKey(ck))));
    expect(await messageKey(ck), isNot(equals(ck)));
    // Fast-forward is exactly repeated stepping.
    expect(await fastForwardChain(ck, 3),
        equals(await nextChainKey(await nextChainKey(await nextChainKey(ck)))));
  });

  test('forward secrecy: after delivery, current state cannot decrypt a '
      'previously captured ciphertext', () async {
    final p = await _pair();
    final service = MessagingService(p.relay);
    final tmp = await Directory.systemTemp.createTemp('gene_fs');
    addTearDown(() => tmp.deleteSync(recursive: true));

    await service.send(p.alice,
        seq: 1,
        videoPath: _fakeVideoNamed(tmp, 'f.mp4', List<int>.filled(600, 3)).path,
        durationMs: 100);

    // A wiretap of the relay captures the sealed entry in transit.
    final captured = p.relay.entryCiphertext(p.bob.inboundFeedId, 1)!;

    // Bob receives it; his persisted state advances (cursor 1, chain at 2).
    final inbox = await Directory.systemTemp.createTemp('gene_fs_in');
    addTearDown(() => inbox.deleteSync(recursive: true));
    final r = await service.fetchNew(p.bob, mediaDir: inbox);
    expect(r.received, hasLength(1));
    final bobAfter = p.bob.copyWith(
      inboundCursor: r.cursor,
      inboundChainKey: r.inboundChainKey,
    );

    // Compromise the device NOW: everything it holds is bobAfter. The chain is
    // one-way, so the key for seq 1 must be underivable — the captured
    // ciphertext stays sealed.
    final staleKey = await messageKey(bobAfter.inboundChainKey);
    await expectLater(Crypto.open(staleKey, captured), throwsA(anything));
    // And a re-fetch with the advanced state cannot re-deliver it either
    // (cursor is past it; the relay copy would normally be destroyed on ack).
    final again = await service.fetchNew(bobAfter, mediaDir: inbox);
    expect(again.received, isEmpty);
  });

  test('a TTL-swept gap is fast-forwarded: later missives still decrypt, the '
      'swept key is consumed forever', () async {
    final p = await _pair();
    final service = MessagingService(p.relay);
    final tmp = await Directory.systemTemp.createTemp('gene_gap');
    addTearDown(() => tmp.deleteSync(recursive: true));

    // Alice sends 1 and 2; the relay's TTL sweep destroys 1 (and its media)
    // before Bob ever collects it.
    await service.send(p.alice,
        seq: 1,
        videoPath: _fakeVideoNamed(tmp, 'g1.mp4', const [1]).path,
        durationMs: 1);
    final firstBlobs = p.relay.mediaIds.toSet();
    await service.send(p.alice,
        seq: 2,
        videoPath: _fakeVideoNamed(tmp, 'g2.mp4', List<int>.filled(300, 9)).path,
        durationMs: 2);
    p.relay.sweepEntry(p.bob.inboundFeedId, 1);
    for (final id in firstBlobs) {
      await p.relay.deleteMedia(id);
    }

    // Bob's fetch walks the chain over the gap and still opens seq 2.
    final inbox = await Directory.systemTemp.createTemp('gene_gap_in');
    addTearDown(() => inbox.deleteSync(recursive: true));
    final r = await service.fetchNew(p.bob, mediaDir: inbox);
    expect(r.received.map((m) => m.seq), [2]);
    expect(r.cursor, 2);
  });

  test('a legacy (v1) stored contact migrates: chains derived, K purged, '
      'messaging still works end-to-end', () async {
    // Hand-craft two v1 contact records sharing a K, as the old format stored
    // them ('k' present, no chain keys).
    final k = Crypto.randomBytes(32);
    final aliceWrite = await Crypto.newSigningKey();
    final bobWrite = await Crypto.newSigningKey();
    final aliceId = await LocalIdentity.generate();
    final bobId = await LocalIdentity.generate();
    Map<String, dynamic> v1(
      List<int> peer,
      List<int> seed,
      String out,
      String inn,
    ) =>
        {
          'peer': base64.encode(peer),
          'k': base64.encode(k),
          'out': out,
          'seed': base64.encode(seed),
          'in': inn,
          'name': null,
          'seqOut': 1,
          'curIn': 0,
        };

    final aliceStorage = MemSecureStorage({
      'gene.contacts': jsonEncode([
        v1(bobId.publicKey, await Crypto.seedOf(aliceWrite), 'feedA', 'feedB'),
      ]),
    });
    final bobStorage = MemSecureStorage({
      'gene.contacts': jsonEncode([
        v1(aliceId.publicKey, await Crypto.seedOf(bobWrite), 'feedB', 'feedA'),
      ]),
    });

    final alice =
        (await ContactStore(storage: aliceStorage).load()).single;
    final bob = (await ContactStore(storage: bobStorage).load()).single;

    // K is purged from storage by the migration save-back.
    expect(aliceStorage.data['gene.contacts'], isNot(contains('"k"')));
    // Peers derived matching chains from the same K.
    expect(alice.outboundChainKey, equals(bob.inboundChainKey));

    // And the migrated contacts interoperate end-to-end.
    final relay = InMemoryRelay();
    final service = MessagingService(relay);
    final tmp = await Directory.systemTemp.createTemp('gene_migrate');
    addTearDown(() => tmp.deleteSync(recursive: true));
    await service.send(alice,
        seq: 1,
        videoPath: _fakeVideoNamed(tmp, 'm.mp4', List<int>.filled(200, 4)).path,
        durationMs: 50);
    final inbox = await Directory.systemTemp.createTemp('gene_migrate_in');
    addTearDown(() => inbox.deleteSync(recursive: true));
    final r = await service.fetchNew(bob, mediaDir: inbox);
    expect(r.received, hasLength(1));
  });
}
