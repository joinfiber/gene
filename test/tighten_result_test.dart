import 'package:flutter_test/flutter_test.dart';
import 'package:gene/src/editor/tighten_result.dart';

void main() {
  group('TightenResult', () {
    const result = TightenResult(
      outputPath: '/tmp/out.mp4',
      originalMs: 36200,
      keptMs: 27400,
      segments: 21,
    );

    test('derives removed seconds and percent shorter', () {
      expect(result.removedSeconds, closeTo(8.8, 0.0001));
      expect(result.percentShorter, 24);
    });

    test('caption summarizes the edit', () {
      expect(result.caption, contains('8.8s · 21 segs · 24% shorter'));
    });

    test('never divides by zero for an empty original', () {
      const empty = TightenResult(
        outputPath: '/tmp/out.mp4',
        originalMs: 0,
        keptMs: 0,
        segments: 1,
      );
      expect(empty.percentShorter, 0);
    });
  });
}
