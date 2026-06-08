import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gene/src/editor/editor_providers.dart';
import 'package:gene/src/editor/tighten_result.dart';
import 'package:path_provider/path_provider.dart';

/// Drives one auto-edit: analyze audio → splice to the speech keep-ranges →
/// write the output file. Its published state is simply whether an edit is in
/// flight (so the UI can show a busy overlay); the [TightenResult] is returned
/// to the caller to present and navigate to.
class TightenController extends Notifier<bool> {
  @override
  bool build() => false;

  Future<TightenResult> tighten(String inputPath) async {
    state = true;
    try {
      final editor = ref.read(editorApiProvider);
      final detection = await editor.detectKeepRanges(inputPath);
      if (detection.ranges.isEmpty) {
        // Nothing to trim (silence / no speech) — pass the original through as a
        // no-op edit so the take can still be reviewed and sent, rather than
        // failing the flow.
        return TightenResult(
          outputPath: inputPath,
          originalMs: detection.originalMs,
          keptMs: detection.originalMs,
          segments: 0,
        );
      }
      final dir = await getTemporaryDirectory();
      final output =
          '${dir.path}/tightened_${DateTime.now().millisecondsSinceEpoch}.mp4';
      await editor.tighten(inputPath, detection.ranges, output);
      return TightenResult(
        outputPath: output,
        originalMs: detection.originalMs,
        keptMs: detection.keptMs,
        segments: detection.ranges.length,
      );
    } finally {
      state = false;
    }
  }
}

final tightenControllerProvider =
    NotifierProvider<TightenController, bool>(TightenController.new);
