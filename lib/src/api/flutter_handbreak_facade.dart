import '../image/image_compression_options.dart';
import '../image/image_compressor.dart';
import '../image/image_format.dart';
import '../models/compression_progress.dart';
import '../models/compression_result.dart';
import '../models/media_info.dart';
import '../presets/video_preset.dart';
import '../probe/handbreak_probe.dart';
import '../video/rate_control.dart';
import '../video/video_compression_options.dart';
import '../video/video_compressor.dart';

/// Lightweight, HandBrake-inspired facade — easy to use, quality-first.
///
/// ```dart
/// final r = await FlutterHandbreak.compressVideo('/a.mp4', quality: 80);
/// final r2 = await FlutterHandbreak.compressVideo('/a.mp4', preset: VideoPreset.balanced);
/// final r3 = await FlutterHandbreak.compressImage('/a.jpg', quality: 82);
/// ```
class FlutterHandbreak {
  FlutterHandbreak._();

  /// Compress any video format (mp4/mov/mkv/webm/...) — HandBrake-style fallback
  /// ensures output is always a playable mp4/mov even when input container is exotic.
  ///
  /// [quality] 0..100 unified scale (80 = balanced). Maps codec-aware to native CRF.
  /// Use [preset] for curated settings (socialMedia, messaging, etc.) — overrides [quality].
  static Future<CompressionResult> compressVideo(
    String inputPath, {
    int quality = 80,
    VideoPresetId? preset,
    String? outputPath,
    void Function(CompressionProgress)? onProgress,
  }) async {
    final q = quality.clamp(0, 100);
    VideoCompressionOptions opts;
    if (preset != null) {
      opts = preset.toOptions();
    } else {
      final vq = q >= 90
          ? VideoQuality.veryHigh
          : q >= 75
              ? VideoQuality.high
              : q >= 60
                  ? VideoQuality.medium
                  : q >= 40
                      ? VideoQuality.low
                      : VideoQuality.veryLow;
      opts = VideoCompressionOptions(rateControl: RateControl.constantQuality(vq));
    }
    final job = await VideoCompressor.start(inputPath, options: opts, outputPath: outputPath);
    if (onProgress != null) job.progress.listen(onProgress);
    return job.result;
  }

  /// Explicit options escape hatch — HandBrake-grade control.
  static Future<CompressionResult> compressVideoWithOptions(
    String inputPath,
    VideoCompressionOptions options, {
    String? outputPath,
    void Function(CompressionProgress)? onProgress,
  }) async {
    final job = await VideoCompressor.start(inputPath, options: options, outputPath: outputPath);
    if (onProgress != null) job.progress.listen(onProgress);
    return job.result;
  }

  /// Compress any image (jpeg/png/webp/heic/avif) — auto format, never grows file by default.
  static Future<CompressionResult> compressImage(
    String inputPath, {
    int quality = 82,
    int maxSide = 2048,
    ImageFormat format = ImageFormat.auto,
    String? outputPath,
  }) async {
    return ImageCompressor.compress(
      inputPath,
      options: ImageCompressionOptions(
        quality: quality.clamp(0, 100),
        maxWidth: maxSide,
        maxHeight: maxSide,
        format: format,
      ),
      outputPath: outputPath,
    );
  }

  static Future<MediaInfo> probe(String path) => HandbreakProbe.probe(path);
}
