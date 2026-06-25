import 'dart:convert';
import 'dart:io';

import 'package:gene/src/messaging/models.dart';
import 'package:path_provider/path_provider.dart';

/// Persists the local missive library — the received missives this device keeps
/// once the relay copy is destroyed on ack. Metadata lives in a JSON file in the
/// app documents directory; the decrypted media files sit alongside it under
/// `missives/`.
///
/// This is the plaintext library by design (the decrypted videos are on disk to
/// be played), distinct from the secret-bearing [ContactStore] which uses the
/// Keystore.
///
/// **Durability is the point here:** this index is the *only* record tying a
/// kept video to its sender once the relay copy is destroyed on ack, so it earns
/// more care than a plain overwrite:
///  - **writes are atomic** — a temp file is flushed to disk, then renamed over
///    the target, so a crash mid-write can never leave a torn/partial index;
///  - **load never throws** — a corrupt index is quarantined, not propagated, so
///    one bad file can't make the whole library permanently unreadable;
///  - **a lost index is rebuilt from disk** — every media file is named
///    `<feedId>-<seq>.mp4`, which is enough to reconstruct the library rather
///    than silently starting empty (which the next sync would then persist,
///    turning a transient loss into a permanent one).
class MessageStore {
  MessageStore({Directory? directory}) : _directoryOverride = directory;

  final Directory? _directoryOverride;
  static const _fileName = 'gene_missives.json';
  static const _tmpName = 'gene_missives.json.tmp';
  static const _mediaSubdir = 'missives';

  Future<Directory> directory() async =>
      _directoryOverride ?? await getApplicationDocumentsDirectory();

  Future<File> _file() async => File('${(await directory()).path}/$_fileName');
  Future<File> _tmpFile() async =>
      File('${(await directory()).path}/$_tmpName');
  Future<Directory> _mediaDir() async =>
      Directory('${(await directory()).path}/$_mediaSubdir');

  /// Load the library, preferring a temp left by an interrupted atomic write
  /// (by construction the most-recent flushed state), then the committed index,
  /// then a reconstruction from the media on disk. Never throws: a file that
  /// won't parse is quarantined and the next source is tried, so a corrupt index
  /// degrades to "rebuild from disk", not "library gone".
  Future<List<ReceivedMissive>> load() async {
    // Temp first: if a crash landed between flush and rename, the temp holds the
    // newer state and the committed file is the previous good copy. After a clean
    // save the temp is gone, so this is a no-op in the normal case.
    for (final file in [await _tmpFile(), await _file()]) {
      if (!file.existsSync()) continue;
      try {
        return _decode(await file.readAsString());
      } catch (_) {
        await _quarantine(file);
      }
    }
    return _rebuildFromDisk();
  }

  /// Persist [missives] atomically: flush a temp file, then rename it over the
  /// index. `rename` is an atomic replace on POSIX; on Windows it won't clobber
  /// an existing file, so fall back to delete-then-rename — the freshly-flushed
  /// temp still survives a crash in that window, and [load] recovers from it.
  Future<void> save(List<ReceivedMissive> missives) async {
    final tmp = await _tmpFile();
    await tmp.writeAsString(
      jsonEncode([for (final m in missives) m.toJson()]),
      flush: true,
    );
    final target = await _file();
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      if (target.existsSync()) await target.delete();
      await tmp.rename(target.path);
    }
  }

  List<ReceivedMissive> _decode(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return [
      for (final e in list) ReceivedMissive.fromJson(e as Map<String, dynamic>),
    ];
  }

  /// Move a corrupt index aside (best-effort) so it isn't retried and is left
  /// for inspection, without blocking startup.
  Future<void> _quarantine(File file) async {
    try {
      final corrupt = File('${file.path}.corrupt');
      if (corrupt.existsSync()) await corrupt.delete();
      await file.rename(corrupt.path);
    } catch (_) {
      // Best-effort: if we can't move it, the next successful save overwrites it.
    }
  }

  /// Reconstruct the library from the decrypted media files still on disk. Each
  /// is named `<feedId>-<seq>.mp4`, which carries the feed and the seq; the seq
  /// is the trailing digits after the final '-', so a feed id that itself
  /// contains '-' (base64url) is parsed correctly. Duration is unknown (shown as
  /// 0) and the file's mtime stands in for the receive time.
  ///
  /// Invariant for any future missive-delete feature: delete the media FILE too
  /// (or write a tombstone), or a later rebuild here will resurrect a missive the
  /// user deleted — the on-disk file is the source of truth on this path.
  Future<List<ReceivedMissive>> _rebuildFromDisk() async {
    final dir = await _mediaDir();
    if (!dir.existsSync()) return [];
    final out = <ReceivedMissive>[];
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.mp4')) continue;
      final name = entity.uri.pathSegments.last;
      final stem = name.substring(0, name.length - '.mp4'.length);
      final dash = stem.lastIndexOf('-');
      if (dash <= 0 || dash == stem.length - 1) continue;
      final seq = int.tryParse(stem.substring(dash + 1));
      if (seq == null) continue;
      out.add(ReceivedMissive(
        inboundFeedId: stem.substring(0, dash),
        seq: seq,
        fileName: name,
        durationMs: 0,
        receivedAtMs: entity.statSync().modified.millisecondsSinceEpoch,
      ));
    }
    out.sort((a, b) => a.seq.compareTo(b.seq));
    return out;
  }
}
