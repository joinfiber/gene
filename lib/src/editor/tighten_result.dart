/// The outcome of one auto-edit, with the presentation math kept out of the UI.
class TightenResult {
  const TightenResult({
    required this.outputPath,
    required this.originalMs,
    required this.keptMs,
    required this.segments,
  });

  final String outputPath;
  final int originalMs;
  final int keptMs;
  final int segments;

  double get removedSeconds => (originalMs - keptMs) / 1000.0;

  int get percentShorter =>
      originalMs > 0 ? (100 * (originalMs - keptMs) / originalMs).round() : 0;

  /// e.g. "−8.5s · 14 segs · 24% shorter".
  String get caption =>
      '−${removedSeconds.toStringAsFixed(1)}s · '
      '$segments segs · $percentShorter% shorter';
}
