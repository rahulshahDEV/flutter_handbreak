import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_handbreak/handbreak.dart';

void main() {
  group('VideoPreset mapping', () {
    test('all presets produce valid options', () {
      for (final id in VideoPresetId.values) {
        final opts = id.toOptions();
        expect(
          () => opts.validate(),
          returnsNormally,
          reason: 'preset $id invalid',
        );
      }
    });
    test('fast is hardwarePreferred and low quality', () {
      final opts = VideoPresetId.fast.toOptions();
      expect(opts.hardwareAcceleration, HardwareAcceleration.hardwarePreferred);
      expect(
        (opts.rateControl as ConstantQualityRateControl).quality,
        VideoQuality.low,
      );
      expect(opts.maxWidth, 1280);
    });
    test('balanced is medium quality 1080p', () {
      final opts = VideoPresetId.balanced.toOptions();
      expect(
        (opts.rateControl as ConstantQualityRateControl).quality,
        VideoQuality.medium,
      );
      expect(opts.maxWidth, 1920);
      expect(opts.codec, VideoCodec.h264);
    });
    test('socialMedia is always h264 for compatibility', () {
      final opts =
          VideoPresetId.socialMedia.toOptions(codecOverride: VideoCodec.h265);
      // socialMedia hardcodes h264 regardless of override? Check impl — it hardcodes h264
      expect(opts.codec, VideoCodec.h264);
      expect(opts.maxHeight, 1920); // portrait-capable
      expect(opts.maxWidth, 1080);
    });
    test('messaging is smallest with mono audio', () {
      final opts = VideoPresetId.messaging.toOptions();
      expect(opts.audio.mixdown, 'mono');
      expect(opts.audio.bitrateKbps, 64);
    });
    test('archive preserves resolution (no max)', () {
      final opts = VideoPresetId.archive.toOptions();
      expect(opts.maxWidth, isNull);
      expect(opts.maxHeight, isNull);
      expect(opts.audio.mode, AudioMode.copy);
      expect(opts.container, VideoContainer.mkv);
    });
    test('smallFile uses hevc', () {
      final opts = VideoPresetId.smallFile.toOptions();
      expect(opts.codec, VideoCodec.h265);
    });
    test('codecOverride respected where allowed', () {
      final opts =
          VideoPresetId.balanced.toOptions(codecOverride: VideoCodec.av1);
      expect(opts.codec, VideoCodec.av1);
    });
    test('presetName is set', () {
      for (final id in VideoPresetId.values) {
        expect(id.toOptions().presetName, id.name);
      }
    });
  });
}
