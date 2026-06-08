import 'package:pigeon/pigeon.dart';

// Type-safe contract between Dart and the native (Kotlin) editor engine.
// Regenerate with:  dart run pigeon --input pigeons/editor_api.dart
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/editor/editor_api.g.dart',
    kotlinOut:
        'android/app/src/main/kotlin/dev/gene/editor/EditorApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'dev.gene.editor'),
    dartPackageName: 'gene',
  ),
)

/// A span of the source recording to keep, in milliseconds.
class KeepRange {
  KeepRange({required this.startMs, required this.endMs});
  final int startMs;
  final int endMs;
}

/// The outcome of analyzing a recording's audio for dead air.
class DetectionResult {
  DetectionResult({
    required this.ranges,
    required this.originalMs,
    required this.keptMs,
  });

  /// Speech spans to retain, in order.
  final List<KeepRange?> ranges;

  /// Duration of the original recording (ms).
  final int originalMs;

  /// Total duration retained after trimming (ms).
  final int keptMs;
}

/// On-device video editor, implemented natively (Android: MediaCodec + Media3).
@HostApi()
abstract class EditorApi {
  /// Analyzes [inputPath]'s audio and returns the speech keep-ranges,
  /// trimming dead air and collapsing long pauses.
  @async
  DetectionResult detectKeepRanges(String inputPath);

  /// Clips [inputPath] to [keepRanges], concatenates the kept spans, and
  /// writes a single mp4 to [outputPath]. Returns the output path.
  @async
  String tighten(String inputPath, List<KeepRange?> keepRanges, String outputPath);
}
