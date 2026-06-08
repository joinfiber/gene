import 'package:flutter/material.dart';

import 'package:gene/src/editor/tighten_result.dart';

/// Branded summary of an auto-edit, shown over the tightened playback. Animates
/// in once so the result reads as considered, not merely reported.
class EditSummary extends StatelessWidget {
  const EditSummary({super.key, required this.result});

  final TightenResult result;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      label: 'Auto-edit result: ${result.caption}',
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => Opacity(
          opacity: t.clamp(0.0, 1.0).toDouble(),
          child: Transform.translate(
            offset: Offset(0, 18 * (1 - t)),
            child: child,
          ),
        ),
        child: Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Wordmark(accent: accent),
              const SizedBox(height: 12),
              _Headline(percent: result.percentShorter, accent: accent),
              const SizedBox(height: 5),
              Text(
                '${result.removedSeconds.toStringAsFixed(1)}s of dead air'
                ' trimmed · ${result.segments} cuts',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.66),
                  fontSize: 13,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.auto_awesome, size: 15, color: accent),
        const SizedBox(width: 7),
        const Text(
          'gene',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(width: 9),
        Text(
          'AUTO-EDIT',
          style: TextStyle(
            color: accent,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.8,
          ),
        ),
      ],
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.percent, required this.accent});

  final int percent;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '$percent%',
          style: TextStyle(
            color: accent,
            fontSize: 36,
            fontWeight: FontWeight.w800,
            height: 1,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(width: 8),
        const Padding(
          padding: EdgeInsets.only(bottom: 3),
          child: Text(
            'tighter',
            style: TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
