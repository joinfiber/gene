import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:gene/src/pairing/models.dart';
import 'package:gene/src/storage/secure_storage.dart';

/// Persists paired contacts (each carries secret material — the conversation
/// key and a per-feed signing seed) in platform secure storage.
class ContactStore {
  ContactStore({FlutterSecureStorage? storage})
      : _storage = storage ?? geneSecureStorage;

  final FlutterSecureStorage _storage;
  static const _contactsKey = 'gene.contacts';

  Future<List<Contact>> load() async {
    final raw = await _storage.read(key: _contactsKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return [
      for (final entry in list) Contact.fromJson(entry as Map<String, dynamic>),
    ];
  }

  Future<void> save(List<Contact> contacts) async {
    await _storage.write(
      key: _contactsKey,
      value: jsonEncode([for (final c in contacts) c.toJson()]),
    );
  }
}
