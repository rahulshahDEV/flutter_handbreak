import 'dart:async';
import 'dart:io';

import '../models/compression_job.dart';
import '../models/compression_result.dart';
import '../platform/handbreak_platform_interface.dart';
import '../utils/validation.dart';
import 'image_compression_options.dart';

class ImageCompressor {
  ImageCompressor._();

  static HandbreakPlatform get _impl {
    HandbreakPlatform.ensureInitialized();
    return HandbreakPlatform.instance;
  }

  /// One-shot image compression. Returns [CompressionResult] (or a subclass
  /// carrying image-specific fields from native).
  static Future<CompressionResult> compress(
    String inputPath, {
    ImageCompressionOptions options = const ImageCompressionOptions(),
    String? outputPath,
  }) async {
    final job =
        await start(inputPath, options: options, outputPath: outputPath);
    try {
      return await job.result;
    } finally {
      try {
        await _impl.disposeJob(job.id).timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
  }

  /// Start with progress + cancellation support.
  static Future<CompressionJob> start(
    String inputPath, {
    ImageCompressionOptions options = const ImageCompressionOptions(),
    String? outputPath,
  }) async {
    options.validate();
    Validation.requireFileExists(inputPath);
    final out = _resolveOutputPath(inputPath, outputPath);
    Validation.requireOutputWritable(
      out,
      overwriteExisting: options.overwriteExisting,
    );
    Validation.requireNotSameFile(inputPath, out);

    final jobId = await _impl.startImageCompression(
      inputPath: inputPath,
      outputPath: out,
      options: options.toMap(),
    );
    return CompressionJob(
      id: jobId,
      progress: _impl.progressStream(jobId),
      result: _impl.waitForResult(jobId),
      cancelFn: () => _impl.cancelJob(jobId),
    );
  }

  static String _resolveOutputPath(String inputPath, String? desired) {
    if (desired != null && desired.isNotEmpty) return desired;
    final dir = File(inputPath).parent.path;
    final base = File(inputPath).uri.pathSegments.last.split('.').first;
    final suffix = DateTime.now().millisecondsSinceEpoch % 100000;
    return '$dir/${base}_handbreak_$suffix.jpg';
  }
}
