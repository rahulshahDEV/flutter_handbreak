/// Returned after mux+validate. Re-probed output is embedded as [outputMediaInfo].
class CompressionResult {
  const CompressionResult({
    required this.inputPath,
    required this.outputPath,
    required this.originalSizeBytes,
    required this.outputSizeBytes,
    required this.savedBytes,
    required this.compressionRatio,
    required this.compressionPercentage,
    required this.durationMs,
    required this.usedHardwareAcceleration,
    required this.codec,
    required this.container,
    this.outputMediaInfo,
    this.estimatedOutputSizeBytes,
    this.qualityWarning,
    this.wasKeptOriginal = false,
  });

  final String inputPath;
  final String outputPath;
  final int originalSizeBytes;
  final int outputSizeBytes;
  final int savedBytes;
  /// original / output (e.g. 3.2 = ~69% saved).
  final double compressionRatio;
  /// 0..100 percentage saved.
  final double compressionPercentage;
  final int durationMs; // wall-clock encode time
  final bool usedHardwareAcceleration;
  final String codec;
  final String container;
  final Map<String, dynamic>? outputMediaInfo;

  /// Returned by native when estimation is possible under CQ.
  final int? estimatedOutputSizeBytes;

  /// Set when recompressing already-heavily-compressed material likely degrades quality.
  final String? qualityWarning;

  /// True when [keepOriginalIfSmaller] kept the original because output would be larger.
  final bool wasKeptOriginal;

  bool get didSaveSpace => savedBytes > 0;

  Duration get duration => Duration(milliseconds: durationMs);

  factory CompressionResult.fromMap(Map<String, dynamic> m) => CompressionResult(
        inputPath: m['inputPath'] as String? ?? '',
        outputPath: m['outputPath'] as String? ?? '',
        originalSizeBytes: m['originalSizeBytes'] as int? ?? 0,
        outputSizeBytes: m['outputSizeBytes'] as int? ?? 0,
        savedBytes: m['savedBytes'] as int? ?? 0,
        compressionRatio: (m['compressionRatio'] as num?)?.toDouble() ?? 1.0,
        compressionPercentage: (m['compressionPercentage'] as num?)?.toDouble() ?? 0,
        durationMs: m['durationMs'] as int? ?? 0,
        usedHardwareAcceleration: m['usedHardwareAcceleration'] as bool? ?? false,
        codec: m['codec'] as String? ?? 'h264',
        container: m['container'] as String? ?? 'mp4',
        outputMediaInfo: m['outputMediaInfo'] as Map<String, dynamic>?,
        estimatedOutputSizeBytes: m['estimatedOutputSizeBytes'] as int?,
        qualityWarning: m['qualityWarning'] as String?,
        wasKeptOriginal: m['wasKeptOriginal'] as bool? ?? false,
      );

  Map<String, dynamic> toMap() => {
        'inputPath': inputPath,
        'outputPath': outputPath,
        'originalSizeBytes': originalSizeBytes,
        'outputSizeBytes': outputSizeBytes,
        'savedBytes': savedBytes,
        'compressionRatio': compressionRatio,
        'compressionPercentage': compressionPercentage,
        'durationMs': durationMs,
        'usedHardwareAcceleration': usedHardwareAcceleration,
        'codec': codec,
        'container': container,
        'outputMediaInfo': outputMediaInfo,
        'estimatedOutputSizeBytes': estimatedOutputSizeBytes,
        'qualityWarning': qualityWarning,
        'wasKeptOriginal': wasKeptOriginal,
      };

  @override
  String toString() =>
      'CompressionResult(${_fmt(originalSizeBytes)}→${_fmt(outputSizeBytes)} '
      '${compressionPercentage.toStringAsFixed(1)}% saved in ${durationMs}ms '
      'hw:$usedHardwareAcceleration $codec/$container)';

  static String _fmt(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
}
