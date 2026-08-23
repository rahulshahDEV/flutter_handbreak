import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_handbreak/handbreak.dart';

void main() {
  group('VideoCompressionOptions validation', () {
    test('valid minimal options pass', () {
      const opts = VideoCompressionOptions();
      expect(() => opts.validate(), returnsNormally);
    });
    test('negative maxWidth throws', () {
      const opts = VideoCompressionOptions(maxWidth: -100);
      expect(() => opts.validate(), throwsArgumentError);
    });
    test('zero maxHeight throws', () {
      const opts = VideoCompressionOptions(maxHeight: 0);
      expect(() => opts.validate(), throwsArgumentError);
    });
    test('scale out of range throws', () {
      const opts = VideoCompressionOptions(scale: 0);
      expect(() => opts.validate(), throwsArgumentError);
      expect(() => const VideoCompressionOptions(scale: 5).validate(), throwsArgumentError);
    });
    test('maxFrameRate zero throws', () {
      const opts = VideoCompressionOptions(maxFrameRate: 0);
      expect(() => opts.validate(), throwsArgumentError);
    });
    test('quality convenience sets effectiveRateControl', () {
      const opts = VideoCompressionOptions(quality: VideoQuality.high);
      expect(opts.effectiveRateControl, isA<ConstantQualityRateControl>());
      expect((opts.effectiveRateControl as ConstantQualityRateControl).quality, VideoQuality.high);
    });
    test('rateControl takes precedence when quality not set', () {
      const opts = VideoCompressionOptions(rateControl: RateControl.averageBitrate(2000));
      expect(opts.effectiveRateControl, isA<AverageBitrateRateControl>());
    });
    test('toMap round-trips codec and frameRateMode', () {
      const opts = VideoCompressionOptions(codec: VideoCodec.h265, frameRateMode: FrameRateMode.constant, maxFrameRate: 30, hardwareAcceleration: HardwareAcceleration.hardwareOnly);
      final m = opts.toMap();
      expect(m['codec'], 'h265');
      expect(m['frameRateMode'], 'constant');
      expect(m['maxFrameRate'], 30);
      expect(m['hardwareAcceleration'], 'hardwareOnly');
    });
    test('copyWith preserves unchanged fields', () {
      const base = VideoCompressionOptions(codec: VideoCodec.h264, maxWidth: 1920);
      final copied = base.copyWith(codec: VideoCodec.h265);
      expect(copied.codec, VideoCodec.h265);
      expect(copied.maxWidth, 1920);
    });
    test('ImageCompressionOptions quality range', () {
      expect(() => ImageCompressionOptions(quality: 101).validate(), throwsArgumentError);
      expect(() => ImageCompressionOptions(quality: -1).validate(), throwsArgumentError);
      expect(() => ImageCompressionOptions(quality: 82).validate(), returnsNormally);
    });
  });

  group('RateControl', () {
    test('constantQuality toMap', () {
      const rc = RateControl.constantQuality(VideoQuality.medium);
      expect(rc.toMap(), {'mode': 'cq', 'quality': 'medium'});
    });
    test('averageBitrate toMap', () {
      const rc = RateControl.averageBitrate(2500, twoPass: true);
      expect(rc.toMap()['mode'], 'abr');
      expect(rc.toMap()['bitrateKbps'], 2500);
      expect(rc.toMap()['twoPass'], true);
    });
  });
}
