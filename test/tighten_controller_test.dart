import 'dart:async';
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

/// Detection blocks on [gate] so a test can observe the in-flight busy state.
class _BlockingEditorApi extends EditorApi {
  final gate = Completer<DetectionResult>();

  @override
  Future<DetectionResult> detectKeepRanges(String inputPath) => gate.future;

  @override
  Future<String> tighten(
    String inputPath,
    List<KeepRange?> keepRanges,
    String outputPath,
  ) async =>
      outputPath;
}

/// Detection throws, to exercise the failure path.
class _ThrowingEditorApi extends EditorApi {
  @override
  Future<DetectionResult> detectKeepRanges(String inputPath) async =>
      throw StateError('decode failed');

  @override
  Future<String> tighten(
    String inputPath,
    List<KeepRange?> keepRanges,
    String outputPath,
  ) async =>
      outputPath;
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

  test('tighten reports busy while in flight and idle once finished', () async {
    final blocking = _BlockingEditorApi();
    final container = ProviderContainer(
      overrides: [editorApiProvider.overrideWithValue(blocking)],
    );
    addTearDown(container.dispose);

    final notifier = container.read(tightenControllerProvider.notifier);
    expect(container.read(tightenControllerProvider), isFalse);

    final future = notifier.tighten('/tmp/in.mp4');
    await Future<void>.delayed(Duration.zero); // let the busy flag publish
    expect(container.read(tightenControllerProvider), isTrue,
        reason: 'busy while the edit is in flight');

    blocking.gate.complete(DetectionResult(
      ranges: [KeepRange(startMs: 0, endMs: 1000)],
      originalMs: 1000,
      keptMs: 1000,
    ));
    await future;
    expect(container.read(tightenControllerProvider), isFalse,
        reason: 'idle once finished');
  });

  test('tighten resets to idle even when detection throws', () async {
    final container = ProviderContainer(
      overrides: [editorApiProvider.overrideWithValue(_ThrowingEditorApi())],
    );
    addTearDown(container.dispose);

    final notifier = container.read(tightenControllerProvider.notifier);
    await expectLater(
      notifier.tighten('/tmp/in.mp4'),
      throwsA(isA<StateError>()),
    );
    expect(container.read(tightenControllerProvider), isFalse,
        reason: 'the finally resets the busy flag on failure');
  });
}
