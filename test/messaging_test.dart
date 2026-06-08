import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gene/src/crypto/primitives.dart';
import 'package:gene/src/messaging/message_crypto.dart';
import 'package:gene/src/messaging/message_store.dart';
import 'package:gene/src/messaging/messaging_providers.dart';
import 'package:gene/src/messaging/messaging_service.dart';
import 'package:gene/src/messaging/models.dart';
import 'package:gene/src/pairing/models.dart';
import 'package:gene/src/pairing/pairing_service.dart';
import 'package:gene/src/pairing/relay_transport.dart';

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
      conversationKey: Crypto.randomBytes(32), // wrong K
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

  test('fetchNew stops at an entry whose media is gone (does not burn the seq)',
      () async {
    final p = await _pair();
    final service = MessagingService(p.relay);
    final tmp = await Directory.systemTemp.createTemp('gene_mm');
    await service.send(p.alice,
        seq: 1,
        videoPath: _fakeVideo(tmp, List<int>.filled(500, 2)).path,
        durationMs: 100);

    // Simulate the blob being swept before the recipient pulled it.
    for (final id in p.relay.mediaIds.toList()) {
      await p.relay.deleteMedia(id);
    }

    final inbox = await Directory.systemTemp.createTemp('gene_mm_in');
    final r = await service.fetchNew(p.bob, mediaDir: inbox);
    expect(r.received, isEmpty);
    expect(r.cursor, 0,
        reason: 'cursor must not advance past an undelivered entry');

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

  test('signedMessage is big-endian seq ‖ ciphertext', () {
    expect(
      signedMessage(1, [0xAA, 0xBB]),
      [0, 0, 0, 0, 0, 0, 0, 1, 0xAA, 0xBB],
    );
    expect(signedMessage(258, const <int>[]), [0, 0, 0, 0, 0, 0, 1, 2]);
  });

  test('per-message subkey is deterministic and bound to feed + seq', () async {
    final k = Crypto.randomBytes(32);
    expect(await messageSubkey(k, 'feed', 1),
        equals(await messageSubkey(k, 'feed', 1)));
    expect(await messageSubkey(k, 'feed', 1),
        isNot(equals(await messageSubkey(k, 'feed', 2))));
    expect(await messageSubkey(k, 'feedA', 1),
        isNot(equals(await messageSubkey(k, 'feedB', 1))));
  });
}
