import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gene/src/recorder/recorder_state.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Owns the camera lifecycle and recording, publishing an immutable
/// [RecorderState]. The live [CameraController] is a mutable native resource,
/// so it's held here (not in the state) and exposed via [camera].
///
/// Three robustness guarantees are baked in:
///  - a wake-lock keeps the screen awake while the camera is open, so the
///    system screen-timeout can't pause us and kill an in-flight recording;
///  - on backgrounding we salvage any in-progress take before teardown;
///  - state is only published while mounted, and disposal finalizes an
///    in-flight recording so a mid-take screen-pop yields a playable file.
class RecorderController extends Notifier<RecorderState> {
  CameraController? _camera;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  bool _initializing = false;
  bool _toggling = false;
  bool _disposed = false;

  /// The live controller for the preview widget; non-null once status is ready.
  CameraController? get camera => _camera;

  @override
  RecorderState build() {
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    ref.onDispose(_disposeResources);
    scheduleMicrotask(_initCamera);
    return const RecorderState();
  }

  /// Publish [next] only while mounted — guards the `state =` writes that follow
  /// `await`s, since a disposed [Notifier] throws on assignment.
  void _publish(RecorderState next) {
    if (!_disposed) state = next;
  }

  Future<void> _initCamera() async {
    if (_initializing || _disposed) return;
    _initializing = true;
    _publish(const RecorderState(status: RecorderStatus.initializing));
    try {
      final camGranted = await Permission.camera.request();
      final micGranted = await Permission.microphone.request();
      if (!camGranted.isGranted || !micGranted.isGranted) {
        _publish(const RecorderState(
          status: RecorderStatus.error,
          errorMessage: 'Camera and microphone permissions are required.',
        ));
        return;
      }
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _publish(const RecorderState(
          status: RecorderStatus.error,
          errorMessage: 'No cameras found.',
        ));
        return;
      }
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        front,
        ResolutionPreset.max,
        enableAudio: true,
      );
      await controller.initialize();
      // Disposed while we were initializing: release the orphan and stop.
      if (_disposed) {
        await controller.dispose();
        return;
      }
      await WakelockPlus.enable();
      _camera = controller;
      _publish(const RecorderState(status: RecorderStatus.ready));
    } catch (e) {
      _publish(RecorderState(
        status: RecorderStatus.error,
        errorMessage: 'Failed to initialize camera: $e',
      ));
    } finally {
      _initializing = false;
    }
  }

  /// Re-initialize after a permission denial or camera error.
  Future<void> retry() => _initCamera();

  /// Drop the current take after it has been sent (or abandoned): delete its file
  /// best-effort so the decrypted recording doesn't linger, and clear the path so
  /// the recorder's stale play/tighten actions disappear. Idempotent.
  Future<void> clearTake() async {
    final path = state.lastRecordingPath;
    _publish(RecorderState(status: state.status));
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {
        // best-effort
      }
    }
  }

  /// Start or stop recording. On a recording error it restores a usable state
  /// and rethrows, so the UI can surface a transient message.
  Future<void> toggleRecording() async {
    final controller = _camera;
    if (controller == null || !controller.value.isInitialized || _toggling) {
      return;
    }
    _toggling = true;
    try {
      if (state.isRecording) {
        _timer?.cancel();
        final file = await controller.stopVideoRecording();
        _publish(state.copyWith(
          status: RecorderStatus.ready,
          lastRecordingPath: file.path,
        ));
      } else {
        final priorTake = state.lastRecordingPath;
        await controller.startVideoRecording();
        // Fresh recording state (drops the prior take's path), then delete that
        // prior take's file so abandoned, unsent recordings don't pile up on disk.
        _publish(const RecorderState(status: RecorderStatus.recording));
        if (priorTake != null) {
          try {
            await File(priorTake).delete();
          } catch (_) {
            // best-effort
          }
        }
        _timer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (_disposed) return;
          _publish(state.copyWith(
            elapsed: state.elapsed + const Duration(seconds: 1),
          ));
        });
      }
    } catch (_) {
      _timer?.cancel();
      _publish(state.copyWith(status: RecorderStatus.ready));
      rethrow;
    } finally {
      _toggling = false;
    }
  }

  Future<void> _onLifecycle(AppLifecycleState lifecycle) async {
    if (lifecycle == AppLifecycleState.resumed) {
      if (_camera == null && !_initializing) await _initCamera();
      return;
    }
    if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.detached) {
      await _teardown(salvage: true);
    }
    // 'inactive' is transient (brief focus loss) — keep the camera alive.
  }

  /// Release the camera; if [salvage] and we were recording, stop+save first.
  Future<void> _teardown({bool salvage = false}) async {
    _timer?.cancel();
    final controller = _camera;
    if (controller == null) return;
    if (salvage && controller.value.isRecordingVideo) {
      try {
        final file = await controller.stopVideoRecording();
        _publish(state.copyWith(lastRecordingPath: file.path));
      } catch (_) {
        // best effort on the way out
      }
    }
    await WakelockPlus.disable();
    await controller.dispose();
    _camera = null;
    _publish(state.copyWith(status: RecorderStatus.initializing));
  }

  void _disposeResources() {
    final takePath = state.lastRecordingPath;
    _disposed = true;
    _timer?.cancel();
    _lifecycle?.dispose();
    final controller = _camera;
    _camera = null;
    // onDispose is synchronous, so finalize as a best-effort fire-and-forget:
    // stop any in-flight recording (so the file is finalized, not corrupt),
    // release the camera, drop the wake-lock, and delete any unsent take so the
    // decrypted recording doesn't outlive the session.
    unawaited(_finalize(controller, takePath));
  }

  Future<void> _finalize(CameraController? controller, String? takePath) async {
    try {
      if (controller != null) {
        if (controller.value.isRecordingVideo) {
          try {
            await controller.stopVideoRecording();
          } catch (_) {
            // best effort
          }
        }
        await controller.dispose();
      }
    } finally {
      await WakelockPlus.disable();
      if (takePath != null) {
        try {
          await File(takePath).delete();
        } catch (_) {
          // best-effort
        }
      }
    }
  }
}

final recorderControllerProvider =
    NotifierProvider<RecorderController, RecorderState>(RecorderController.new);
