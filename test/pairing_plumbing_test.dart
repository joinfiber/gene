import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gene/src/pairing/http_relay_transport.dart';
import 'package:gene/src/pairing/models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('HttpRelayTransport', () {
    test('putInvite PUTs the raw payload and accepts 201', () async {
      late http.Request seen;
      final transport = HttpRelayTransport(
        baseUrl: 'http://relay',
        client: MockClient((request) async {
          seen = request;
          return http.Response('{"ok":true}', 201);
        }),
      );

      await transport.putInvite('abc', [1, 2, 3]);

      expect(seen.method, 'PUT');
      expect(seen.url.path, '/invite/abc');
      expect(seen.bodyBytes, [1, 2, 3]);
    });

    test('getInvite returns bytes on 200, null on 404', () async {
      final transport = HttpRelayTransport(
        baseUrl: 'http://relay',
        client: MockClient((request) async {
          return request.url.path == '/invite/here'
              ? http.Response.bytes([9, 9], 200)
              : http.Response('{"error":"not_found"}', 404);
        }),
      );

      expect(await transport.getInvite('here'), [9, 9]);
      expect(await transport.getInvite('gone'), isNull);
    });

    test('redeemInvite is true on 200, false on 409', () async {
      final transport = HttpRelayTransport(
        baseUrl: 'http://relay',
        client: MockClient((request) async {
          return request.url.path.contains('taken')
              ? http.Response('', 409)
              : http.Response('{"ok":true}', 200);
        }),
      );

      expect(await transport.redeemInvite('fresh', [1]), isTrue);
      expect(await transport.redeemInvite('taken', [1]), isFalse);
    });

    test('pollRedeem returns null on 204', () async {
      final transport = HttpRelayTransport(
        baseUrl: 'http://relay',
        client: MockClient((request) async => http.Response('', 204)),
      );
      expect(await transport.pollRedeem('x'), isNull);
    });
  });

  test('Contact survives a JSON round-trip (and never serializes a K)', () {
    final contact = Contact(
      peerPublicKey: [1, 2, 3],
      outboundChainKey: List<int>.filled(32, 7),
      inboundChainKey: List<int>.filled(32, 8),
      outboundFeedId: 'out-feed',
      outboundWriteKeySeed: List<int>.filled(32, 9),
      inboundFeedId: 'in-feed',
      name: 'Sam',
      verified: true,
    );

    final json = contact.toJson();
    expect(json.containsKey('k'), isFalse,
        reason: 'the conversation key is never persisted (forward secrecy)');

    final restored = Contact.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
    );

    expect(restored.peerPublicKey, contact.peerPublicKey);
    expect(restored.outboundChainKey, contact.outboundChainKey);
    expect(restored.inboundChainKey, contact.inboundChainKey);
    expect(restored.outboundFeedId, contact.outboundFeedId);
    expect(restored.outboundWriteKeySeed, contact.outboundWriteKeySeed);
    expect(restored.inboundFeedId, contact.inboundFeedId);
    expect(restored.name, 'Sam');
    expect(restored.verified, isTrue);
  });
}
