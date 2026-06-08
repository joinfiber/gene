/// Lifecycle of the recorder surface.
enum RecorderStatus { initializing, ready, recording, error }

/// Immutable snapshot of the recorder. The live `CameraController` is a mutable
/// native resource, so it's owned by the controller — not held in this value.
class RecorderState {
  const RecorderState({
    this.status = RecorderStatus.initializing,
    this.lastRecordingPath,
    this.elapsed = Duration.zero,
    this.errorMessage,
  });

  final RecorderStatus status;
  final String? lastRecordingPath;
  final Duration elapsed;
  final String? errorMessage;

  bool get isRecording => status == RecorderStatus.recording;
  bool get hasRecording => lastRecordingPath != null;

  RecorderState copyWith({
    RecorderStatus? status,
    String? lastRecordingPath,
    Duration? elapsed,
  }) {
    return RecorderState(
      status: status ?? this.status,
      lastRecordingPath: lastRecordingPath ?? this.lastRecordingPath,
      elapsed: elapsed ?? this.elapsed,
      // errorMessage only ever travels with a freshly-built error state.
    );
  }
}
