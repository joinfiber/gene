import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gene/src/editor/editor_providers.dart';
import 'package:gene/src/editor/tighten_result.dart';
import 'package:path_provider/path_provider.dart';

/// Drives one auto-edit: analyze audio → splice to the speech keep-ranges →
/// write the output file. Its published state is simply whether an edit is in
/// flight (so the UI can show a busy overlay); the [TightenResult] is returned
/// to the caller to present and navigate to.
class TightenController extends Notifier<bool> {
  /// The last distinct tightened output we wrote, so a re-tighten or an
  /// abandoned review can clean it up rather than leaving decrypted video in the
  /// temp dir. (Deleted by the send path too; a later delete here is a no-op.)
  String? _lastOutput;

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
      // A previously-tightened output that was reviewed but never sent is now
      // superseded; drop it so abandoned edits don't accumulate in temp.
      await _deletePriorOutput();
      final dir = await getTemporaryDirectory();
      final output =
          '${dir.path}/tightened_${DateTime.now().millisecondsSinceEpoch}.mp4';
      await editor.tighten(inputPath, detection.ranges, output);
      _lastOutput = output;
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

  Future<void> _deletePriorOutput() async {
    final prior = _lastOutput;
    _lastOutput = null;
    if (prior != null) {
      try {
        await File(prior).delete();
      } catch (_) {
        // best-effort
      }
    }
  }
}

final tightenControllerProvider =
    NotifierProvider<TightenController, bool>(TightenController.new);
