import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../errors/handbreak_exception.dart';
import '../hardware/hardware_capabilities.dart';
import '../models/compression_progress.dart';
import '../models/compression_result.dart';
import '../models/media_info.dart';
import 'handbreak_platform_interface.dart';

/// MethodChannel implementation of [HandbreakPlatform].
///
/// Commands/metadata flow over `handbreak`; per-job progress flows over
/// lazily-created EventChannels `handbreak/progress/<jobId>`. Streams are
/// broadcast and self-terminate: a terminal event (`done`, or `error`) closes
/// the stream and evicts the cache entry, preventing leaks (P1-4).
class MethodChannelHandbreak extends HandbreakPlatform {
  @visibleForTesting
  static const MethodChannel methodChannel = MethodChannel('handbreak');

  static const String _progressChannelPrefix = 'handbreak/progress/';

  final Map<String, StreamController<CompressionProgress>>
      _progressControllers = {};
  final Set<String> _terminatedJobs = {};

  HandbreakException _errorFrom(Map<String, dynamic> m) => mapNativeError({
        'code': m['code'] as String? ?? 'UNKNOWN',
        'message': m['message'] as String? ?? '',
        'nativeMessage': m['nativeMessage'] as String?,
      });

  @override
  Future<HardwareCapabilities> getHardwareCapabilities() async {
    try {
      final map = await methodChannel
          .invokeMapMethod<String, dynamic>('getHardwareCapabilities');
      if (map == null) {
        throw const EncodingException('getHardwareCapabilities returned null');
      }
      return HardwareCapabilities.fromMap(Map<String, dynamic>.from(map));
    } on PlatformException catch (e) {
      throw mapNativeError({
        'code': e.code,
        'message': e.message,
        'nativeMessage': e.details?.toString(),
      });
    }
  }

  @override
  Future<MediaInfo> probe(String inputPath) async {
    try {
      final map = await methodChannel
          .invokeMapMethod<String, dynamic>('probe', {'inputPath': inputPath});
      if (map == null) throw const EncodingException('probe returned null');
      return MediaInfo.fromMap(Map<String, dynamic>.from(map));
    } on PlatformException catch (e) {
      throw mapNativeError({
        'code': e.code,
        'message': e.message,
        'nativeMessage': e.details?.toString(),
      });
    }
  }

  @override
  Future<String> startVideoCompression({
    required String inputPath,
    required String outputPath,
    required Map<String, dynamic> options,
  }) async {
    return _start(
      'startVideoCompression',
      inputPath: inputPath,
      outputPath: outputPath,
      options: options,
    );
  }

  @override
  Future<String> startImageCompression({
    required String inputPath,
    required String outputPath,
    required Map<String, dynamic> options,
  }) async {
    return _start(
      'startImageCompression',
      inputPath: inputPath,
      outputPath: outputPath,
      options: options,
    );
  }

  Future<String> _start(
    String method, {
    required String inputPath,
    required String outputPath,
    required Map<String, dynamic> options,
  }) async {
    try {
      final jobId = await methodChannel.invokeMethod<String>(method, {
        'inputPath': inputPath,
        'outputPath': outputPath,
        'options': options,
      });
      if (jobId == null || jobId.isEmpty) {
        throw EncodingException('$method returned empty jobId');
      }
      return jobId;
    } on PlatformException catch (e) {
      throw mapNativeError({
        'code': e.code,
        'message': e.message,
        'nativeMessage': e.details?.toString(),
      });
    }
  }

  @override
  Stream<CompressionProgress> progressStream(String jobId) {
    return _progressControllers.putIfAbsent(jobId, () {
      final controller = StreamController<CompressionProgress>.broadcast(
        onCancel: () {
          // Last listener detached and job already terminated → release.
          if (_terminatedJobs.contains(jobId)) {
            _progressControllers.remove(jobId);
            _terminatedJobs.remove(jobId);
          }
        },
      );
      final channel = EventChannel('$_progressChannelPrefix$jobId');
      late final StreamSubscription<dynamic> sub;
      sub = channel.receiveBroadcastStream().listen(
        (event) {
          if (event is! Map) return;
          if (controller.isClosed) return; // terminal already handled elsewhere
          final m = Map<String, dynamic>.from(event);
          if (m.containsKey('error')) {
            controller.addError(
              _errorFrom(Map<String, dynamic>.from(m['error'] as Map)),
            );
            return;
          }
          if (m['done'] == true) {
            _finish(jobId, sub, controller);
            return;
          }
          controller.add(CompressionProgress.fromMap(m));
        },
        onError: (Object e) {
          if (!controller.isClosed) controller.addError(e);
        },
        onDone: () => _finish(jobId, sub, controller),
        cancelOnError: false,
      );
      return controller;
    }).stream;
  }

  void _finish(
    String jobId,
    StreamSubscription<dynamic> sub,
    StreamController<CompressionProgress> c,
  ) {
    _terminatedJobs.add(jobId);
    sub.cancel();
    if (!c.isClosed) c.close();
  }

  /// Internal hook used by waitForResult/dispose to mark terminal state so
  /// cached streams stop holding native channel registrations.
  void _markTerminal(String jobId) {
    _terminatedJobs.add(jobId);
    final c = _progressControllers.remove(jobId);
    if (c != null && !c.isClosed) c.close();
  }

  @override
  Future<CompressionResult> waitForResult(String jobId) async {
    try {
      final map = await methodChannel
          .invokeMapMethod<String, dynamic>('waitForResult', {
        'jobId': jobId,
      }).timeout(
        const Duration(hours: 6),
        onTimeout: () =>
            throw const EncodingException('waitForResult timed out'),
      );
      if (map == null) {
        throw const EncodingException('waitForResult returned null');
      }
      if (map.containsKey('error')) {
        throw _errorFrom(Map<String, dynamic>.from(map['error'] as Map));
      }
      _markTerminal(jobId);
      return CompressionResult.fromMap(Map<String, dynamic>.from(map));
    } on PlatformException catch (e) {
      _markTerminal(jobId);
      throw mapNativeError({
        'code': e.code,
        'message': e.message,
        'nativeMessage': e.details?.toString(),
      });
    } on HandbreakException {
      _markTerminal(jobId);
      rethrow;
    }
  }

  @override
  Future<void> cancelJob(String jobId) async {
    try {
      await methodChannel.invokeMethod<void>('cancelJob', {'jobId': jobId});
    } on PlatformException catch (e) {
      if (e.code == 'CANCELLED') return; // idempotent
      throw mapNativeError({
        'code': e.code,
        'message': e.message,
        'nativeMessage': e.details?.toString(),
      });
    }
  }

  @override
  Future<void> disposeJob(String jobId) async {
    _markTerminal(jobId);
    try {
      await methodChannel.invokeMethod<void>('disposeJob', {'jobId': jobId});
    } catch (_) {
      // dispose is best-effort cleanup
    }
  }
}
