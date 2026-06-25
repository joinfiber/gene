import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gene/src/messaging/message_store.dart';
import 'package:gene/src/messaging/models.dart';

ReceivedMissive _missive(String feed, int seq) => ReceivedMissive(
      inboundFeedId: feed,
      seq: seq,
      fileName: '$feed-$seq.mp4',
      durationMs: 1234,
      receivedAtMs: 1700000000000,
    );

void main() {
  late Directory dir;
  late MessageStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gene_store');
    store = MessageStore(directory: dir);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  File indexFile() => File('${dir.path}/gene_missives.json');
  Directory mediaDir() => Directory('${dir.path}/missives');

  test('save then load round-trips the library', () async {
    final lib = [_missive('feedA', 1), _missive('feedB', 2)];
    await store.save(lib);

    final loaded = await store.load();
    expect(loaded.map((m) => '${m.inboundFeedId}:${m.seq}'),
        ['feedA:1', 'feedB:2']);
    expect(loaded.first.durationMs, 1234);
  });

  test('save leaves no temp file behind (atomic rename consumed it)', () async {
    await store.save([_missive('feedA', 1)]);
    expect(File('${dir.path}/gene_missives.json.tmp').existsSync(), isFalse);
    expect(indexFile().existsSync(), isTrue);
  });

  test('a corrupt index is rebuilt from the media files on disk', () async {
    // The decrypted media exists on disk (named <feedId>-<seq>.mp4)...
    mediaDir().createSync(recursive: true);
    File('${mediaDir().path}/feedA-1.mp4').writeAsBytesSync([1, 2, 3]);
    File('${mediaDir().path}/feedA-2.mp4').writeAsBytesSync([4, 5, 6]);
    // ...but the index itself is torn/corrupt.
    indexFile().writeAsStringSync('{ this is not valid json');

    final loaded = await store.load();

    // The library is recovered from disk rather than silently lost.
    expect(loaded.map((m) => '${m.inboundFeedId}:${m.seq}'),
        ['feedA:1', 'feedA:2']);
    // Degraded-but-safe metadata contract: duration is unknown (0) and the
    // receive time falls back to the media file's mtime.
    final byKey = {for (final m in loaded) '${m.inboundFeedId}:${m.seq}': m};
    expect(byKey['feedA:1']!.durationMs, 0);
    expect(
      byKey['feedA:1']!.receivedAtMs,
      File('${mediaDir().path}/feedA-1.mp4').statSync().modified
          .millisecondsSinceEpoch,
    );
    // The corrupt file was quarantined, not left to be re-read.
    expect(indexFile().existsSync(), isFalse);
    expect(File('${indexFile().path}.corrupt').existsSync(), isTrue);
  });

  test('rebuild parses a feed id that itself contains a dash', () async {
    mediaDir().createSync(recursive: true);
    File('${mediaDir().path}/ab-cd-7.mp4').writeAsBytesSync([0]);

    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.inboundFeedId, 'ab-cd'); // seq is the trailing digits
    expect(loaded.single.seq, 7);
  });

  test('a corrupt index with no media on disk loads empty, never throws',
      () async {
    indexFile().writeAsStringSync('not json at all');
    expect(await store.load(), isEmpty); // graceful, not an exception
  });

  test('an interrupted write (temp present, no committed index) is recovered',
      () async {
    // Simulate a crash after the temp was flushed but before the rename landed.
    File('${dir.path}/gene_missives.json.tmp')
        .writeAsStringSync(jsonEncode([_missive('feedZ', 9).toJson()]));

    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.inboundFeedId, 'feedZ');
    expect(loaded.single.seq, 9);
  });

  test('a fresh store with nothing on disk loads empty', () async {
    expect(await store.load(), isEmpty);
  });
}
