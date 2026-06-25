import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gene/src/pairing/models.dart';
import 'package:gene/src/pairing/pairing_service.dart';
import 'package:gene/src/pairing/relay_transport.dart';

void main() {
  test('two devices pair and derive the same conversation key', () async {
    final relay = InMemoryRelay();
    final alice = await LocalIdentity.generate();
    final bob = await LocalIdentity.generate();

    // Alice mints an invite and shares the link out-of-band.
    final pending = await PairingService.mintInvite(alice, relay, linkBase: 'https://relay.test/i/');
    expect(await pending.tryComplete(relay), isNull); // nobody has redeemed yet

    // Bob redeems it.
    final bobContact =
        await PairingService.redeemInvite(bob, pending.link, relay);

    // Alice completes once the redemption lands.
    final aliceContact = await pending.tryComplete(relay);
    expect(aliceContact, isNotNull);

    // Both derived the *same* conversation key from the ECDH.
    expect(aliceContact!.conversationKey, equals(bobContact.conversationKey));

    // Each knows the other's identity.
    expect(aliceContact.peerPublicKey, equals(bob.publicKey));
    expect(bobContact.peerPublicKey, equals(alice.publicKey));

    // Feeds cross over: my outbound is your inbound, and vice-versa.
    expect(aliceContact.outboundFeedId, equals(bobContact.inboundFeedId));
    expect(bobContact.outboundFeedId, equals(aliceContact.inboundFeedId));
  });

  test('an invite can be redeemed only once', () async {
    final relay = InMemoryRelay();
    final alice = await LocalIdentity.generate();
    final bob = await LocalIdentity.generate();
    final mallory = await LocalIdentity.generate();

    final pending = await PairingService.mintInvite(alice, relay, linkBase: 'https://relay.test/i/');
    await PairingService.redeemInvite(bob, pending.link, relay);

    await expectLater(
      PairingService.redeemInvite(mallory, pending.link, relay),
      throwsA(isA<PairingException>()),
    );
  });

  test('both sides compute the same safety number; a stranger differs',
      () async {
    final relay = InMemoryRelay();
    final alice = await LocalIdentity.generate();
    final bob = await LocalIdentity.generate();

    final pending = await PairingService.mintInvite(alice, relay, linkBase: 'https://relay.test/i/');
    final bobContact =
        await PairingService.redeemInvite(bob, pending.link, relay);
    final aliceContact = (await pending.tryComplete(relay))!;

    final aliceSees = await aliceContact.safetyNumber(alice.publicKey);
    final bobSees = await bobContact.safetyNumber(bob.publicKey);

    // Canonical: identical on both devices regardless of who invited whom.
    expect(aliceSees, equals(bobSees));
    expect(aliceSees, matches(RegExp(r'^(\d{5} ){7}\d{5}$')));

    // A different peer key yields a different number (not fixed or empty).
    final mallory = await LocalIdentity.generate();
    final spoofed = Contact(
      peerPublicKey: mallory.publicKey,
      conversationKey: aliceContact.conversationKey,
      outboundFeedId: aliceContact.outboundFeedId,
      outboundWriteKeySeed: aliceContact.outboundWriteKeySeed,
      inboundFeedId: aliceContact.inboundFeedId,
    );
    expect(
      await spoofed.safetyNumber(alice.publicKey),
      isNot(equals(aliceSees)),
    );
  });

  test('a malformed link is rejected cleanly', () async {
    final relay = InMemoryRelay();
    final bob = await LocalIdentity.generate();

    for (final bad in [
      'not a url at all',
      'https://gene.app/i/abc', // no #secret
      'https://gene.app/i/abc#short', // secret wrong length
    ]) {
      await expectLater(
        PairingService.redeemInvite(bob, bad, relay),
        throwsA(isA<PairingException>()),
      );
    }
  });

  test('a well-formed link with the wrong secret fails cleanly (open failure)',
      () async {
    final relay = InMemoryRelay();
    final alice = await LocalIdentity.generate();
    final bob = await LocalIdentity.generate();
    final pending = await PairingService.mintInvite(alice, relay,
        linkBase: 'https://relay.test/i/');

    // Same (valid) invite id, but a different 32-byte fragment secret, so the
    // seal key is wrong and the sealed payload can't be opened. This exercises
    // the post-fetch crypto-failure branch, not just the pre-network link parse.
    final wrongSecret = base64Url.encode(List<int>.filled(32, 7));
    final tampered = pending.link.replaceFirst(RegExp(r'#.*$'), '#$wrongSecret');

    await expectLater(
      PairingService.redeemInvite(bob, tampered, relay),
      throwsA(isA<PairingException>()),
    );
  });
}
