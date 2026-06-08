import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gene/src/contacts/conversation_screen.dart';
import 'package:gene/src/editor/tighten_controller.dart';
import 'package:gene/src/editor/widgets/edit_summary.dart';
import 'package:gene/src/messaging/messaging_providers.dart';
import 'package:gene/src/pairing/models.dart';
import 'package:gene/src/playback/playback_screen.dart';
import 'package:gene/src/recorder/recorder_controller.dart';
import 'package:gene/src/recorder/recorder_state.dart';
import 'package:gene/src/recorder/widgets/camera_preview_box.dart';
import 'package:gene/src/recorder/widgets/record_button.dart';
import 'package:gene/src/recorder/widgets/status_pill.dart';

/// The capture surface: a full-screen preview with a record control and, once a
/// take exists, play + auto-edit ("tighten"). When opened for a [recipient], the
/// auto-edit step ends on a review screen with a Send button — auto-edit is the
/// product's default, so the path to sending runs through it.
///
/// Each piece watches only the slice of state it needs (via `.select`), so the
/// per-second recording timer rebuilds the timer pill alone — never the preview.
class RecorderScreen extends ConsumerWidget {
  const RecorderScreen({super.key, this.recipient});

  /// The contact this missive is for; null only in standalone/test use.
  final Contact? recipient;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final processing = ref.watch(tightenControllerProvider);
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const _Preview(),
          _Overlay(recipient: recipient),
          if (processing) const _ProcessingOverlay(),
        ],
      ),
    );
  }
}

class _Preview extends ConsumerWidget {
  const _Preview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status =
        ref.watch(recorderControllerProvider.select((s) => s.status));
    if (status == RecorderStatus.initializing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (status == RecorderStatus.error) {
      return const _ErrorView();
    }
    final camera = ref.read(recorderControllerProvider.notifier).camera;
    if (camera == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return CameraPreviewBox(controller: camera);
  }
}

class _ErrorView extends ConsumerWidget {
  const _ErrorView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message =
        ref.watch(recorderControllerProvider.select((s) => s.errorMessage));
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message ?? 'Camera unavailable.', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () =>
                  ref.read(recorderControllerProvider.notifier).retry(),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Overlay extends StatelessWidget {
  const _Overlay({this.recipient});

  final Contact? recipient;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Stack(
        children: [
          const Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: EdgeInsets.only(top: 12),
              child: _TopStatus(),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 32),
              child: _Controls(recipient: recipient),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopStatus extends ConsumerWidget {
  const _TopStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status =
        ref.watch(recorderControllerProvider.select((s) => s.status));
    final elapsed =
        ref.watch(recorderControllerProvider.select((s) => s.elapsed));
    if (status == RecorderStatus.recording) {
      return StatusPill(
        text: '● REC  ${_formatElapsed(elapsed)}',
        highlighted: true,
      );
    }
    final size =
        ref.read(recorderControllerProvider.notifier).camera?.value.previewSize;
    final label = size != null
        ? 'gene · ${size.width.toInt()}×${size.height.toInt()}'
        : 'gene';
    return StatusPill(text: label);
  }
}

class _Controls extends ConsumerWidget {
  const _Controls({this.recipient});

  final Contact? recipient;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (status, hasRecording) = ref.watch(
      recorderControllerProvider.select((s) => (s.status, s.hasRecording)),
    );
    final processing = ref.watch(tightenControllerProvider);
    final recording = status == RecorderStatus.recording;
    final ready = status == RecorderStatus.ready || recording;
    final showTakeActions = hasRecording && !recording;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        SizedBox(
          width: 72,
          child: showTakeActions
              ? IconButton(
                  iconSize: 40,
                  color: Colors.white,
                  icon: const Icon(Icons.play_circle_fill),
                  onPressed: () => _openLastTake(context, ref),
                )
              : const SizedBox.shrink(),
        ),
        RecordButton(
          recording: recording,
          onTap: ready ? () => _toggleRecording(context, ref) : null,
        ),
        SizedBox(
          width: 72,
          child: showTakeActions
              ? IconButton(
                  iconSize: 36,
                  color: Colors.white,
                  icon: const Icon(Icons.auto_fix_high),
                  onPressed:
                      processing ? null : () => _tighten(context, ref, recipient),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _ProcessingOverlay extends StatelessWidget {
  const _ProcessingOverlay();

  @override
  Widget build(BuildContext context) {
    // Absorb pointers so taps can't fall through to the record/play controls
    // while an edit is in flight.
    return AbsorbPointer(
      child: Container(
        color: Colors.black54,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Tightening…'),
            ],
          ),
        ),
      ),
    );
  }
}

// --- actions -------------------------------------------------------------

Future<void> _toggleRecording(BuildContext context, WidgetRef ref) async {
  try {
    await ref.read(recorderControllerProvider.notifier).toggleRecording();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Recording error: $e')));
    }
  }
}

void _openLastTake(BuildContext context, WidgetRef ref) {
  final path = ref.read(recorderControllerProvider).lastRecordingPath;
  if (path == null) return;
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => PlaybackScreen(path: path)),
  );
}

Future<void> _tighten(
  BuildContext context,
  WidgetRef ref,
  Contact? recipient,
) async {
  final path = ref.read(recorderControllerProvider).lastRecordingPath;
  if (path == null) return;
  try {
    final result =
        await ref.read(tightenControllerProvider.notifier).tighten(path);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlaybackScreen(
          path: result.outputPath,
          overlay: EditSummary(result: result),
          sendLabel: recipient == null
              ? 'Send'
              : 'Send to ${recipient.name ?? recipient.shortId}',
          onSend: recipient == null
              ? null
              : () => _sendMissive(
                    context,
                    ref,
                    recipient,
                    result.outputPath,
                    result.keptMs,
                  ),
        ),
      ),
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Tighten failed: $e')));
    }
  }
}

Future<void> _sendMissive(
  BuildContext context,
  WidgetRef ref,
  Contact recipient,
  String path,
  int durationMs,
) async {
  // Capture across the async gap; after sending we pop straight back to the
  // conversation (above the recorder + the review screen).
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  await ref.read(conversationProvider).send(
        recipient,
        videoPath: path,
        durationMs: durationMs,
      );
  if (!context.mounted) return;
  messenger.showSnackBar(
    SnackBar(content: Text('Sent to ${recipient.name ?? recipient.shortId}')),
  );
  navigator.popUntil(
    (route) =>
        route.settings.name == ConversationScreen.routeName || route.isFirst,
  );
}

String _formatElapsed(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}
