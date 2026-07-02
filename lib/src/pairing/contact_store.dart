import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:gene/src/messaging/message_crypto.dart';
import 'package:gene/src/pairing/models.dart';
import 'package:gene/src/storage/secure_storage.dart';

/// Persists paired contacts (each carries secret material — the per-feed chain
/// keys and a per-feed signing seed) in platform secure storage.
class ContactStore {
  ContactStore({FlutterSecureStorage? storage})
      : _storage = storage ?? geneSecureStorage;

  final FlutterSecureStorage _storage;
  static const _contactsKey = 'gene.contacts';

  /// Load contacts, migrating any legacy (v1) record in place. v1 stored the
  /// static conversation key `K`; migration derives the two per-feed ratchet
  /// roots from it, fast-forwards them to the contact's current positions, and
  /// **rewrites storage without `K`** — from then on only forward-advancing
  /// chain state exists on the device (see message_crypto.dart on forward
  /// secrecy). Caveat, stated plainly: entries sealed under the *old* per-seq
  /// scheme that are still undelivered at migration time cannot be opened by
  /// chain keys (different derivation) — both peers must be on the new scheme
  /// with no v1 entries in flight, or re-pair. Fine for this repo's actual
  /// population (dev devices); a deployed system would version entries instead.
  Future<List<Contact>> load() async {
    final raw = await _storage.read(key: _contactsKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    final contacts = <Contact>[];
    var migrated = false;
    for (final entry in list) {
      final json = entry as Map<String, dynamic>;
      if (Contact.isLegacyJson(json)) {
        contacts.add(await _migrateLegacy(json));
        migrated = true;
      } else {
        contacts.add(Contact.fromJson(json));
      }
    }
    // Persist the migration immediately so `K` is purged from storage.
    if (migrated) await save(contacts);
    return contacts;
  }

  Future<void> save(List<Contact> contacts) async {
    await _storage.write(
      key: _contactsKey,
      value: jsonEncode([for (final c in contacts) c.toJson()]),
    );
  }

  Future<Contact> _migrateLegacy(Map<String, dynamic> json) async {
    final k = base64.decode(json['k'] as String);
    final outboundFeedId = json['out'] as String;
    final inboundFeedId = json['in'] as String;
    final outboundSeq = json['seqOut'] as int? ?? 1;
    final inboundCursor = json['curIn'] as int? ?? 0;
    // Roots sit at position 1; fast-forward to where this contact actually is
    // (outbound chain ≡ outboundSeq, inbound chain ≡ inboundCursor + 1).
    final outRoot = await chainRoot(k, outboundFeedId);
    final inRoot = await chainRoot(k, inboundFeedId);
    return Contact(
      peerPublicKey: base64.decode(json['peer'] as String),
      outboundChainKey: await fastForwardChain(outRoot, outboundSeq - 1),
      inboundChainKey: await fastForwardChain(inRoot, inboundCursor),
      outboundFeedId: outboundFeedId,
      outboundWriteKeySeed: base64.decode(json['seed'] as String),
      inboundFeedId: inboundFeedId,
      name: json['name'] as String?,
      outboundSeq: outboundSeq,
      inboundCursor: inboundCursor,
    );
  }
}
