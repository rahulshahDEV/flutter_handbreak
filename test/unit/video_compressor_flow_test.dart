import 'dart:async';
import 'dart:io';

import 'package:flutter_handbreak/flutter_handbreak.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory platform fake — verifies the Dart-side orchestration without
/// touching MethodChannel (audit: probe+caps parallel, plan embedding,
/// error mapping, dispose-on-exit).
class FakeHandbreakPlatform extends HandbreakPlatform {
  int probeCalls = 0;
  int capsCalls = 0;
  int disposeCalls = 0;
  bool cancelled = false;
  Map<String, dynamic>? lastOptions;
  String? lastOutputPath;
  Completer<CompressionResult>? resultCompleter;

  @override
  Future<HardwareCapabilities> getHardwareCapabilities() async {
    capsCalls++;
    return const HardwareCapabilities(
      supportsHardwareH264Encode: true,
      supportsHardwareH265Encode: false,
      supportsHardwareAv1Encode: false,
      supportsHardwareVp9Encode: false,
      supportsHardwareDecode: true,
      platform: 'android',
    );
  }

  @override
  Future<MediaInfo> probe(String inputPath) async {
    probeCalls++;
    return MediaInfo.fromMap({
      'path': inputPath,
      'container': 'mp4',
      'durationMs': 10000,
      'fileSizeBytes': 5000000,
      'overallBitrate': 4000000,
      'videoStreams': [
        {
          'index': 0,
          'codec': 'h264',
          'codecString': 'h264',
          'width': 1920,
          'height': 1080,
          'rotation': 0,
          'frameRate': 30.0,
          'averageFrameRate': 30.0,
          'isVariableFrameRate': false,
          'durationMs': 10000,
          'bitRate': 3500000,
          'pixelFormat': 'yuv420p',
          'colorPrimaries': 'bt709',
          'colorTransfer': 'bt709',
          'colorMatrix': 'bt709',
          'colorRange': 'limited',
          'bitDepth': 8,
          'isHdr': false,
          'displayAspectRatio': 1.77,
          'sampleAspectRatio': 1.0,
        }
      ],
      'audioStreams': [],
      'metadata': {},
    });
  }

  @override
  Future<String> startVideoCompression({
    required String inputPath,
    required String outputPath,
    required Map<String, dynamic> options,
  }) async {
    lastOptions = options;
    lastOutputPath = outputPath;
    resultCompleter = Completer<CompressionResult>();
    return 'fake-job-1';
  }

  @override
  Future<String> startImageCompression({
    required String inputPath,
    required String outputPath,
    required Map<String, dynamic> options,
  }) async {
    return 'fake-img-1';
  }

  @override
  Stream<CompressionProgress> progressStream(String jobId) {
    return const Stream.empty();
  }

  @override
  Future<CompressionResult> waitForResult(String jobId) async {
    // Re-check cancel asynchronously — mirrors real native timing (the job may
    // be cancelled after start() but before the result future resolves).
    await Future<void>.delayed(Duration.zero);
    if (cancelled) {
      throw const CancelledCompressionException();
    }
    final c = resultCompleter;
    if (c != null && !c.isCompleted) {
      c.complete(CompressionResult.fromMap({
        'inputPath': '/fake/in.mp4',
        'outputPath': '/fake/out.mp4',
        'originalSizeBytes': 5000000,
        'outputSizeBytes': 1500000,
        'savedBytes': 3500000,
        'compressionRatio': 3.3,
        'compressionPercentage': 70.0,
        'durationMs': 1200,
        'usedHardwareAcceleration': true,
        'codec': 'h264',
        'container': 'mp4',
      }),);
    }
    return c!.future;
  }

  @override
  Future<void> cancelJob(String jobId) async {
    cancelled = true;
  }

  @override
  Future<void> disposeJob(String jobId) async {
    disposeCalls++;
  }
}

void main() {
  late FakeHandbreakPlatform fake;
  late Directory tmp;
  late String inputPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hb_flow');
    inputPath = '${tmp.path}/in.mp4';
    File(inputPath).writeAsStringSync('x');
    HandbreakPlatform.resetForTesting();
    fake = FakeHandbreakPlatform();
    HandbreakPlatform.instance = fake;
  });

  tearDown(() {
    HandbreakPlatform.resetForTesting();
    tmp.deleteSync(recursive: true);
  });

  group('VideoCompressor.start — Dart orchestration', () {
    test('probes, resolves plan, embeds plan in options', () async {
      final job = await VideoCompressor.start(
        inputPath,
        options: const VideoCompressionOptions(maxWidth: 1280),
        outputPath: '${tmp.path}/out.mp4',
      );
      expect(fake.probeCalls, 1);
      expect(fake.capsCalls, 1);
      expect(fake.lastOutputPath, '${tmp.path}/out.mp4');

      final opts = fake.lastOptions!;
      expect(opts['plan'], isA<Map<String, dynamic>>());
      final plan = ResolvedPlan.fromMap(
          Map<String, dynamic>.from(opts['plan'] as Map),);
      expect(plan.width, 1280); // capped
      expect(plan.height, 720);
      expect(plan.containerId, 'mp4');
      expect(plan.audio.mode, isNotEmpty);

      final result = await job.result;
      expect(result.compressionPercentage, 70.0);
      expect(result.usedHardwareAcceleration, isTrue);
    });

    test('capabilities failure degrades to software-only, job still runs',
        () async {
      fake = _FailingCapsPlatform();
      HandbreakPlatform.resetForTesting();
      HandbreakPlatform.instance = fake;
      final job = await VideoCompressor.start(
        inputPath,
        outputPath: '${tmp.path}/out.mp4',
      );
      final plan = ResolvedPlan.fromMap(
          Map<String, dynamic>.from(fake.lastOptions!['plan'] as Map),);
      expect(plan.useHardware, isFalse);
      expect(await job.result, isA<CompressionResult>());
    });

    test('cancel surfaces CancelledCompressionException', () async {
      final job = await VideoCompressor.start(
        inputPath,
        outputPath: '${tmp.path}/out.mp4',
      );
      await job.cancel();
      await expectLater(job.result, throwsA(isA<CancelledCompressionException>()));
    });

    test('compress() disposes the job after result', () async {
      final result = await VideoCompressor.compress(
        inputPath,
        outputPath: '${tmp.path}/out.mp4',
      );
      expect(result.outputPath, '/fake/out.mp4');
      expect(fake.disposeCalls, 1);
    });
  });
}

class _FailingCapsPlatform extends FakeHandbreakPlatform {
  @override
  Future<HardwareCapabilities> getHardwareCapabilities() async {
    capsCalls++;
    throw const CodecUnavailableException('caps probe failed');
  }
}