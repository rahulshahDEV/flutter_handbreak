import 'dart:async';
import 'dart:io';

import '../errors/handbreak_exception.dart';
import '../hardware/hardware_capabilities.dart';
import '../models/compression_job.dart';
import '../models/compression_result.dart';
import '../platform/handbreak_platform_interface.dart';
import '../utils/validation.dart';
import '../presets/video_preset.dart';
import 'encode_plan_resolver.dart';
import 'video_compression_options.dart';

/// Name used for capability lookups when the platform query itself failed.
const String defaultTargetPlatformName = 'unknown';

class VideoCompressor {
  VideoCompressor._();

  /// Returns the registered platform implementation, lazily registering the
  /// method-channel default when the app hasn't injected one. Tests inject a
  /// mock via [HandbreakPlatform.instance] before calling compressors.
  static HandbreakPlatform platform() {
    HandbreakPlatform.ensureInitialized();
    return HandbreakPlatform.instance;
  }

  /// Simple one-shot compress — wraps [start] + `await job.result`.
  static Future<CompressionResult> compress(
    String inputPath, {
    VideoCompressionOptions options = const VideoCompressionOptions(),
    String? outputPath,
  }) async {
    final job =
        await start(inputPath, options: options, outputPath: outputPath);
    try {
      return await job.result;
    } finally {
      // fire-and-forget dispose is intentional; ignore if platform rejects
      try {
        await platform().disposeJob(job.id).timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
  }

  /// Start a job and return a live handle with progress stream and cancel.
  ///
  /// Pipeline: validate → probe → EncodePlanResolver.resolve() → native execute(plan).
  /// All policy (dimensions, fps gate, container fallback, rate control,
  /// hardware decision, audio plan, filter order) is computed here in tested
  /// Dart and shipped to natives as an execution plan.
  static Future<CompressionJob> start(
    String inputPath, {
    VideoCompressionOptions options = const VideoCompressionOptions(),
    String? outputPath,
  }) async {
    options.validate();
    Validation.requireFileExists(inputPath);
    final out =
        _resolveOutputPath(inputPath, outputPath, options.container.extension);
    Validation.requireOutputWritable(
      out,
      overwriteExisting: options.overwriteExisting,
    );
    Validation.requireNotSameFile(inputPath, out);

    final impl = platform();

    // Probe + capabilities in parallel — both are native I/O (audit P2-6).
    // Capabilities are best-effort: any failure degrades to software-only.
    final infoFuture = impl.probe(inputPath);
    final capsFuture = impl
        .getHardwareCapabilities()
        .then<HardwareCapabilities?>((c) => c)
        .catchError((Object _) => null);
    final (info, capsOpt) = await (infoFuture, capsFuture).wait;
    final caps = capsOpt ??
        HardwareCapabilities(
          supportsHardwareH264Encode: false,
          supportsHardwareH265Encode: false,
          supportsHardwareAv1Encode: false,
          supportsHardwareVp9Encode: false,
          supportsHardwareDecode: false,
          platform: _platformName(impl),
        );

    final plan =
        EncodePlanResolver.resolve(info: info, opts: options, caps: caps);

    final jobId = await impl.startVideoCompression(
      inputPath: inputPath,
      outputPath: out,
      options: {...options.toMap(), 'plan': plan.toMap()},
    );

    final progress = impl.progressStream(jobId);
    final resultFuture = impl.waitForResult(jobId).timeout(
          const Duration(hours: 6),
          onTimeout: () =>
              throw const EncodingException('Compression timed out'),
        );

    return CompressionJob(
      id: jobId,
      progress: progress,
      result: resultFuture,
      cancelFn: () => impl.cancelJob(jobId),
    );
  }

  /// Preset-based convenience.
  static Future<CompressionResult> compressWithPreset(
    String inputPath,
    VideoPresetId preset, {
    String? outputPath,
    VideoCompressionOptions Function(VideoCompressionOptions base)? override,
  }) async {
    var opts = preset.toOptions();
    if (override != null) opts = override(opts);
    return compress(inputPath, options: opts, outputPath: outputPath);
  }

  static bool isValidInput(String path) => Validation.fileExistsQuietly(path);

  static String _platformName(HandbreakPlatform impl) {
    try {
      return impl.runtimeType.toString().contains('MethodChannel')
          ? 'host'
          : 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  static String _resolveOutputPath(
    String inputPath,
    String? desired,
    String extension,
  ) {
    if (desired != null && desired.isNotEmpty) return desired;
    final dir = File(inputPath).parent.path;
    final base = File(inputPath).uri.pathSegments.last.split('.').first;
    final suffix = DateTime.now().millisecondsSinceEpoch % 100000;
    return '$dir/${base}_handbreak_$suffix$extension';
  }
}
