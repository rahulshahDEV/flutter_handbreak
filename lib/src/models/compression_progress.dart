/// Progress based on actual media timestamps/frames — mirrors sync.c's frame_count/est_frame_count model.
/// Never faked with timers.
class CompressionProgress {
  const CompressionProgress({
    required this.progress,
    required this.processedDurationMs,
    required this.totalDurationMs,
    required this.encodedFrames,
    required this.totalFrames,
    required this.currentFps,
    this.estimatedRemainingMs,
    this.stage,
  });

  /// 0.0..1.0 — clamped like sync.c does.
  final double progress;

  /// Already processed media time, not wall-clock.
  final int processedDurationMs;
  final int totalDurationMs;
  final int encodedFrames;
  final int totalFrames;
  final double currentFps;
  final int? estimatedRemainingMs;
  final String? stage; // probe | decode | filter | encode | mux | validate

  double get progressPercent => progress * 100;

  Duration? get estimatedRemaining => estimatedRemainingMs != null
      ? Duration(milliseconds: estimatedRemainingMs!)
      : null;

  Duration get processedDuration => Duration(milliseconds: processedDurationMs);
  Duration get totalDuration => Duration(milliseconds: totalDurationMs);

  factory CompressionProgress.fromMap(Map<String, dynamic> m) =>
      CompressionProgress(
        progress: ((m['progress'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0),
        processedDurationMs: m['processedDurationMs'] as int? ?? 0,
        totalDurationMs: m['totalDurationMs'] as int? ?? 0,
        encodedFrames: m['encodedFrames'] as int? ?? 0,
        totalFrames: m['totalFrames'] as int? ?? 0,
        currentFps: (m['currentFps'] as num?)?.toDouble() ?? 0,
        estimatedRemainingMs: m['estimatedRemainingMs'] as int?,
        stage: m['stage'] as String?,
      );

  Map<String, dynamic> toMap() => {
        'progress': progress,
        'processedDurationMs': processedDurationMs,
        'totalDurationMs': totalDurationMs,
        'encodedFrames': encodedFrames,
        'totalFrames': totalFrames,
        'currentFps': currentFps,
        'estimatedRemainingMs': estimatedRemainingMs,
        'stage': stage,
      };

  @override
  String toString() =>
      'CompressionProgress(${(progress * 100).toStringAsFixed(1)}% $encodedFrames/$totalFrames ${currentFps.toStringAsFixed(1)}fps stage:$stage)';
}
