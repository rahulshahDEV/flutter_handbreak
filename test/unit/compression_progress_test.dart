import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_handbreak/handbreak.dart';

void main() {
  group('CompressionProgress', () {
    test('fromMap clamps progress to 0..1', () {
      final p = CompressionProgress.fromMap({
        'progress': 1.5,
        'processedDurationMs': 0,
        'totalDurationMs': 1000,
        'encodedFrames': 0,
        'totalFrames': 0,
        'currentFps': 0.0,
      });
      expect(p.progress, 1.0);
      final q = CompressionProgress.fromMap({
        'progress': -0.5,
        'processedDurationMs': 0,
        'totalDurationMs': 1000,
        'encodedFrames': 0,
        'totalFrames': 0,
        'currentFps': 0.0,
      });
      expect(q.progress, 0.0);
    });
    test('progressPercent is 0..100', () {
      const p = CompressionProgress(
        progress: 0.5,
        processedDurationMs: 500,
        totalDurationMs: 1000,
        encodedFrames: 15,
        totalFrames: 30,
        currentFps: 30,
      );
      expect(p.progressPercent, 50);
    });
    test('estimatedRemaining from map', () {
      final p = CompressionProgress.fromMap({
        'progress': 0.5,
        'processedDurationMs': 500,
        'totalDurationMs': 1000,
        'encodedFrames': 15,
        'totalFrames': 30,
        'currentFps': 30.0,
        'estimatedRemainingMs': 500,
      });
      expect(p.estimatedRemaining, const Duration(milliseconds: 500));
    });
    test('toMap round-trips', () {
      const p = CompressionProgress(
        progress: 0.75,
        processedDurationMs: 750,
        totalDurationMs: 1000,
        encodedFrames: 22,
        totalFrames: 30,
        currentFps: 28.5,
        estimatedRemainingMs: 250,
        stage: 'encode',
      );
      final m = p.toMap();
      final r = CompressionProgress.fromMap(m);
      expect(r.progress, 0.75);
      expect(r.stage, 'encode');
      expect(r.encodedFrames, 22);
    });
  });

  group('CompressionResult', () {
    test('fromMap computes fields', () {
      final r = CompressionResult.fromMap({
        'inputPath': '/a.mp4',
        'outputPath': '/b.mp4',
        'originalSizeBytes': 1000000,
        'outputSizeBytes': 400000,
        'savedBytes': 600000,
        'compressionRatio': 2.5,
        'compressionPercentage': 60.0,
        'durationMs': 1200,
        'usedHardwareAcceleration': true,
        'codec': 'h264',
        'container': 'mp4',
      });
      expect(r.didSaveSpace, true);
      expect(r.compressionPercentage, 60.0);
      expect(r.usedHardwareAcceleration, true);
    });
    test('wasKeptOriginal flag', () {
      final r = CompressionResult.fromMap({
        'inputPath': '/a.mp4',
        'outputPath': '/a.mp4',
        'originalSizeBytes': 1000,
        'outputSizeBytes': 1000,
        'savedBytes': 0,
        'compressionRatio': 1.0,
        'compressionPercentage': 0.0,
        'durationMs': 10,
        'usedHardwareAcceleration': false,
        'codec': 'jpeg',
        'container': 'jpeg',
        'wasKeptOriginal': true,
      });
      expect(r.wasKeptOriginal, true);
    });
  });

  group('HandbreakException mapping', () {
    test('mapNativeError produces typed exceptions', () {
      expect(
        mapNativeError({'code': 'INVALID_INPUT', 'message': 'bad'}),
        isA<InvalidInputException>(),
      );
      expect(
        mapNativeError({'code': 'HARDWARE_UNAVAILABLE', 'message': 'no hw'}),
        isA<HardwareEncoderUnavailableException>(),
      );
      expect(
        mapNativeError({'code': 'CANCELLED', 'message': 'cancel'}),
        isA<CancelledCompressionException>(),
      );
      expect(
        mapNativeError({'code': 'UNKNOWN_CODE', 'message': 'x'}),
        isA<EncodingException>(),
      );
    });
  });

  group('HardwareCapabilities', () {
    test('fromMap and supportsEncodeFor', () {
      final caps = HardwareCapabilities.fromMap({
        'supportsHardwareH264Encode': true,
        'supportsHardwareH265Encode': false,
        'supportsHardwareAv1Encode': false,
        'supportsHardwareVp9Encode': false,
        'supportsHardwareDecode': true,
        'platform': 'android',
      });
      expect(caps.supportsEncodeFor('h264'), true);
      expect(caps.supportsEncodeFor('h265'), false);
      expect(caps.supportsHardwareH264, true);
    });
  });

  group('MediaInfo', () {
    test('fromMap with video+audio', () {
      final m = MediaInfo.fromMap({
        'path': '/a.mp4',
        'container': 'mp4',
        'durationMs': 10000,
        'fileSizeBytes': 5000000,
        'overallBitrate': 4000000,
        'videoStreams': [
          {
            'index': 0,
            'codec': 'h264',
            'codecString': 'video/avc',
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
        'audioStreams': [
          {
            'index': 0,
            'codec': 'aac',
            'codecString': 'audio/mp4a-latm',
            'sampleRate': 44100,
            'channelCount': 2,
            'bitRate': 128000,
          }
        ],
        'metadata': {},
      });
      expect(m.hasVideo, true);
      expect(m.hasAudio, true);
      expect(m.primaryVideo!.width, 1920);
      expect(m.isPortrait, false);
    });
    test('portrait detection with rotation', () {
      final m = MediaInfo.fromMap({
        'path': '/p.mp4',
        'container': 'mp4',
        'durationMs': 5000,
        'fileSizeBytes': 2000000,
        'overallBitrate': 3200000,
        'videoStreams': [
          {
            'index': 0,
            'codec': 'h264',
            'codecString': 'video/avc',
            'width': 1080,
            'height': 1920,
            'rotation': 0,
            'frameRate': 30.0,
            'averageFrameRate': 30.0,
            'isVariableFrameRate': false,
            'durationMs': 5000,
            'bitRate': 3000000,
            'pixelFormat': 'yuv420p',
            'colorPrimaries': 'bt709',
            'colorTransfer': 'bt709',
            'colorMatrix': 'bt709',
            'colorRange': 'limited',
            'bitDepth': 8,
            'isHdr': false,
            'displayAspectRatio': 0.5625,
            'sampleAspectRatio': 1.0,
          }
        ],
        'audioStreams': [],
        'metadata': {},
      });
      expect(m.isPortrait, true);
    });
  });
}
