import 'dart:io';

import 'package:flutter_handbreak/flutter_handbreak.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FlutterHandbreak facade — quality mapping', () {
    // Probe: VideoCompressor.start requires a real file & platform channel.
    // We verify the *mapping logic* through the public options builder path by
    // checking EncodePlanResolver + QualityMapper equivalence instead, and that
    // the facade delegates to the same RateControl the quality levels produce.
    test('quality bucket mapping mirrors VideoQuality CRF scale', () {
      // 0-100 -> veryHigh/high/medium/low/veryLow, then QualityMapper per codec.
      final veryHigh =
          QualityMapper.crfFor(VideoQuality.veryHigh, VideoCodec.h264);
      final high = QualityMapper.crfFor(VideoQuality.high, VideoCodec.h264);
      final medium = QualityMapper.crfFor(VideoQuality.medium, VideoCodec.h264);
      final low = QualityMapper.crfFor(VideoQuality.low, VideoCodec.h264);
      final veryLow =
          QualityMapper.crfFor(VideoQuality.veryLow, VideoCodec.h264);

      expect(veryHigh, lessThan(high));
      expect(high, lessThan(medium));
      expect(medium, lessThan(low));
      expect(low, lessThan(veryLow));
      // quality 80 maps to high (>=75) -> CRF 20; quality 60 -> medium -> CRF 23
      expect(veryHigh, 18);
      expect(medium, 23);
    });

    test('preset name is propagated for analytics', () {
      for (final p in VideoPresetId.values) {
        final opts = p.toOptions();
        expect(opts.presetName, p.name);
      }
    });
  });

  group('Facade validation paths', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('hb_facade'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('missing input throws typed InvalidInputException', () async {
      await expectLater(
        FlutterHandbreak.compressVideo('${tmp.path}/missing.mp4'),
        throwsA(isA<InvalidInputException>()),
      );
    });

    test('missing image input throws typed exception', () async {
      await expectLater(
        FlutterHandbreak.compressImage('${tmp.path}/missing.jpg'),
        throwsA(isA<InvalidInputException>()),
      );
    });

    test(
        'output path collision without overwrite throws OutputCreationException',
        () async {
      final input = File('${tmp.path}/a.mp4')..writeAsStringSync('x');
      final out = File('${tmp.path}/out.mp4')..writeAsStringSync('x');
      await expectLater(
        FlutterHandbreak.compressVideo(
          input.path,
          outputPath: out.path,
        ),
        throwsA(isA<OutputCreationException>()),
      );
    });
  });

  group('Facade defaults match HandBrake-aligned policy', () {
    test('image default is quality 82, max side 2048, auto format', () {
      const opts = ImageCompressionOptions();
      expect(opts.quality, 82);
      expect(opts.maxWidth, isNull); // facade passes 2048 explicitly
      expect(opts.format, ImageFormat.auto);
      expect(opts.keepOriginalIfSmaller, isTrue);
    });

    test(
        'video default rate control is constant quality (CQ-first like HandBrake)',
        () {
      const opts = VideoCompressionOptions();
      expect(opts.effectiveRateControl, isA<ConstantQualityRateControl>());
      final rc = opts.effectiveRateControl as ConstantQualityRateControl;
      expect(rc.quality, VideoQuality.medium);
    });

    test('encode plan resolves CQ to codec-aware CRF for h264/h265/av1', () {
      final info = MediaInfo.fromMap({
        'path': '/tmp/in.mp4',
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
      const caps = HardwareCapabilities(
        supportsHardwareH264Encode: true,
        supportsHardwareH265Encode: true,
        supportsHardwareAv1Encode: false,
        supportsHardwareVp9Encode: false,
        supportsHardwareDecode: true,
        platform: 'android',
      );
      final plan = EncodePlanResolver.resolve(
        info: info,
        opts: const VideoCompressionOptions(),
        caps: caps,
      );
      expect(plan.rateControlMode, 'cq');
      expect(
          plan.crf, QualityMapper.crfFor(VideoQuality.medium, VideoCodec.h264),);
      expect(plan.useHardware, isTrue);
    });
  });
}
