import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gene/src/editor/editor_api.g.dart';
import 'package:gene/src/editor/editor_providers.dart';
import 'package:gene/src/editor/tighten_controller.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Stand-in for the native engine: returns a fixed detection and echoes the
/// output path without touching the platform.
class _FakeEditorApi extends EditorApi {
  @override
  Future<DetectionResult> detectKeepRanges(String inputPath) async {
    return DetectionResult(
      ranges: [
        KeepRange(startMs: 0, endMs: 2000),
        KeepRange(startMs: 3000, endMs: 5000),
      ],
      originalMs: 6000,
      keptMs: 4000,
    );
  }

  @override
  Future<String> tighten(
    String inputPath,
    List<KeepRange?> keepRanges,
    String outputPath,
  ) async {
    return outputPath;
  }
}

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _FakePathProvider();

  test('tighten builds a result from the detection and returns to idle',
      () async {
    final container = ProviderContainer(
      overrides: [editorApiProvider.overrideWithValue(_FakeEditorApi())],
    );
    addTearDown(container.dispose);

    expect(container.read(tightenControllerProvider), isFalse);

    final result = await container
        .read(tightenControllerProvider.notifier)
        .tighten('/tmp/in.mp4');

    expect(result.originalMs, 6000);
    expect(result.keptMs, 4000);
    expect(result.segments, 2);
    expect(result.percentShorter, 33);
    expect(container.read(tightenControllerProvider), isFalse);
  });
}
