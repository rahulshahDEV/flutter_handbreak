import 'dart:async';

import 'package:meta/meta.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../hardware/hardware_capabilities.dart';
import '../models/compression_progress.dart';
import '../models/compression_result.dart';
import '../models/media_info.dart';
import 'method_channel_handbreak.dart';

/// Stable async platform contract — mirrrors HandBrake's job/probe lifecycle.
///
/// MethodChannel/Pigeon transports commands/metadata; heavy media stays native.
/// Frames are NEVER sent over the channel.
abstract class HandbreakPlatform extends PlatformInterface {
  HandbreakPlatform() : super(token: _token);
  static final Object _token = Object();

  static HandbreakPlatform? _instance;
  static bool _initialized = false;

  static HandbreakPlatform get instance {
    if (_instance == null) ensureInitialized();
    return _instance!;
  }

  static set instance(HandbreakPlatform inst) {
    PlatformInterface.verify(inst, _token);
    _instance = inst;
    _initialized = true;
  }

  /// Registers the default method-channel implementation exactly once.
  /// Safe to call repeatedly; tests may pre-assign [instance] to inject mocks.
  static void ensureInitialized() {
    if (_initialized && _instance != null) return;
    _instance ??= MethodChannelHandbreak();
    _initialized = true;
  }

  /// Test-only: reset registration (used between unit tests).
  @visibleForTesting
  static void resetForTesting() {
    _instance = null;
    _initialized = false;
  }

  Future<HardwareCapabilities> getHardwareCapabilities();
  Future<MediaInfo> probe(String inputPath);

  /// Start a transcode. Progress is streamed via EventChannel `handbreak/progress/<jobId>`.
  /// Returns a jobId; caller polls `getProgressStream(jobId)` and awaits `waitForResult(jobId)`.
  Future<String> startVideoCompression({
    required String inputPath,
    required String outputPath,
    required Map<String, dynamic> options,
  });

  Future<String> startImageCompression({
    required String inputPath,
    required String outputPath,
    required Map<String, dynamic> options,
  });

  Stream<CompressionProgress> progressStream(String jobId);

  Future<CompressionResult> waitForResult(String jobId);

  Future<void> cancelJob(String jobId);

  Future<void> disposeJob(String jobId);
}
