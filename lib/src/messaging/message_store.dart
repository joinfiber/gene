import 'dart:convert';
import 'dart:io';

import 'package:gene/src/messaging/models.dart';
import 'package:path_provider/path_provider.dart';

/// Persists the local missive library — the received missives this device keeps
/// once the relay copy is destroyed on ack. Metadata lives in a JSON file in the
/// app documents directory; the decrypted media files sit alongside it.
///
/// This is the plaintext library by design (the decrypted videos are on disk to
/// be played), distinct from the secret-bearing [ContactStore] which uses the
/// Keystore.
class MessageStore {
  MessageStore({Directory? directory}) : _directoryOverride = directory;

  final Directory? _directoryOverride;
  static const _fileName = 'gene_missives.json';

  Future<Directory> directory() async =>
      _directoryOverride ?? await getApplicationDocumentsDirectory();

  Future<File> _file() async => File('${(await directory()).path}/$_fileName');

  Future<List<ReceivedMissive>> load() async {
    final file = await _file();
    if (!file.existsSync()) return [];
    final list = jsonDecode(await file.readAsString()) as List<dynamic>;
    return [
      for (final e in list) ReceivedMissive.fromJson(e as Map<String, dynamic>),
    ];
  }

  Future<void> save(List<ReceivedMissive> missives) async {
    final file = await _file();
    await file.writeAsString(
      jsonEncode([for (final m in missives) m.toJson()]),
    );
  }
}
