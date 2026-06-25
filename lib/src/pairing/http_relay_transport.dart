import 'dart:convert';

import 'package:gene/src/pairing/relay_transport.dart';
import 'package:http/http.dart' as http;

/// [RelayTransport] over HTTP against the live Worker. Opaque bodies (sealed
/// payloads, media) are raw bytes; feed entries are JSON with base64 fields —
/// matching the relay's documented contract (see relay/README.md). The relay
/// only ever sees opaque ciphertext and public keys.
class HttpRelayTransport implements RelayTransport {
  HttpRelayTransport({
    required this.baseUrl,
    http.Client? client,
    Duration timeout = const Duration(seconds: 60),
  })  : _client = client ?? http.Client(),
        _timeout = timeout;

  final String baseUrl;
  final http.Client _client;

  /// Per-request ceiling. Bounds a stalled request so it can't pin a feed's send
  /// queue (or a sync) indefinitely; on elapse the call throws `TimeoutException`
  /// and the caller treats it as a retryable failure.
  final Duration _timeout;

  static const _jsonHeaders = {'content-type': 'application/json'};

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<http.Response> _timed(Future<http.Response> request) =>
      request.timeout(_timeout);

  // --- pairing -------------------------------------------------------------

  @override
  Future<void> putInvite(String id, List<int> sealedPayload) async {
    final response =
        await _timed(_client.put(_uri('/invite/$id'), body: sealedPayload));
    if (response.statusCode == 409) throw StateError('invite already exists');
    _expect(response, 201);
  }

  @override
  Future<List<int>?> getInvite(String id) async {
    final response = await _timed(_client.get(_uri('/invite/$id')));
    if (response.statusCode == 404) return null;
    _expect(response, 200);
    return response.bodyBytes;
  }

  @override
  Future<bool> redeemInvite(String id, List<int> sealedResponse) async {
    final response = await _timed(
        _client.post(_uri('/invite/$id/redeem'), body: sealedResponse));
    // 409 already_redeemed, or 404 the slot is gone (expired between our
    // getInvite and this redeem — a TOCTOU window): either way we did not claim
    // it, so report "not redeemed" cleanly rather than throwing a raw 404.
    if (response.statusCode == 409 || response.statusCode == 404) return false;
    _expect(response, 200);
    return true;
  }

  @override
  Future<List<int>?> pollRedeem(String id) async {
    final response = await _timed(_client.get(_uri('/invite/$id/redeem')));
    if (response.statusCode == 204) return null; // not redeemed yet
    _expect(response, 200);
    return response.bodyBytes;
  }

  // --- feeds ---------------------------------------------------------------

  @override
  Future<void> createFeed(String id, List<int> authorPublicKey) async {
    final response =
        await _timed(_client.put(_uri('/feed/$id'), body: authorPublicKey));
    if (response.statusCode == 409) return; // already bound
    _expect(response, 201);
  }

  @override
  Future<void> appendEntry(String feedId, FeedEntry entry) async {
    final response = await _timed(_client.post(
      _uri('/feed/$feedId/entry'),
      headers: _jsonHeaders,
      body: jsonEncode({
        'seq': entry.seq,
        'sig': base64.encode(entry.signature),
        'ct': base64.encode(entry.ciphertext),
      }),
    ));
    if (response.statusCode == 404) throw FeedNotFoundException(feedId);
    if (response.statusCode == 409) {
      throw _errorCode(response.body) == 'stale_seq'
          ? StaleSeqException(feedId, entry.seq)
          : DuplicateSeqException(feedId, entry.seq);
    }
    _expect(response, 201);
  }

  @override
  Future<List<FeedEntry>> fetchEntries(String feedId, {int since = 0}) async {
    final response =
        await _timed(_client.get(_uri('/feed/$feedId?since=$since')));
    _expect(response, 200);
    // A 200 with an unexpected shape (a buggy or hostile relay) becomes a typed
    // RelayException rather than a raw CastError/FormatException. Entry contents
    // are still signature-verified downstream, so this is robustness, not the
    // security boundary.
    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return [
        for (final e in data['entries'] as List<dynamic>)
          FeedEntry(
            seq: (e as Map<String, dynamic>)['seq'] as int,
            signature: base64.decode(e['sig'] as String),
            ciphertext: base64.decode(e['ct'] as String),
          ),
      ];
    } catch (_) {
      throw RelayException(response.statusCode, response.body);
    }
  }

  @override
  Future<int> ackEntries(String feedId, int upTo) async {
    final response = await _timed(_client.post(
      _uri('/feed/$feedId/ack'),
      headers: _jsonHeaders,
      body: jsonEncode({'upTo': upTo}),
    ));
    if (response.statusCode == 404) throw FeedNotFoundException(feedId);
    _expect(response, 200);
    try {
      return (jsonDecode(response.body) as Map<String, dynamic>)['deleted']
          as int;
    } catch (_) {
      throw RelayException(response.statusCode, response.body);
    }
  }

  // --- media ---------------------------------------------------------------

  @override
  Future<void> putMedia(String id, List<int> bytes) async {
    final response = await _timed(_client.put(_uri('/media/$id'), body: bytes));
    _expect(response, 201);
  }

  @override
  Future<List<int>?> getMedia(String id) async {
    final response = await _timed(_client.get(_uri('/media/$id')));
    // 404 (gone) and 503 (a deploy with no R2 binding) both mean "not available
    // here" — return null so fetchNew skips/retries the entry rather than throwing
    // out of a whole sync.
    if (response.statusCode == 404 || response.statusCode == 503) return null;
    _expect(response, 200);
    return response.bodyBytes;
  }

  @override
  Future<void> deleteMedia(String id) async {
    final response = await _timed(_client.delete(_uri('/media/$id')));
    _expect(response, 204);
  }

  void _expect(http.Response response, int ok) {
    if (response.statusCode != ok) {
      throw RelayException(response.statusCode, response.body);
    }
  }

  /// The `error` code from a relay JSON error body, if any (e.g. `stale_seq`).
  String? _errorCode(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map<String, dynamic> && data['error'] is String) {
        return data['error'] as String;
      }
    } catch (_) {
      // Not JSON — no code.
    }
    return null;
  }
}

class RelayException implements Exception {
  RelayException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'RelayException($statusCode): $body';
}
