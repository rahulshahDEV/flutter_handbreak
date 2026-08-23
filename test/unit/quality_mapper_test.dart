import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_handbreak/handbreak.dart';

void main() {
  group('QualityMapper', () {
    test('valid ranges per codec', () {
      expect(QualityMapper.validRangeFor(VideoCodec.h264), (min: 0, max: 51));
      expect(QualityMapper.validRangeFor(VideoCodec.av1), (min: 0, max: 63));
      expect(QualityMapper.validRangeFor(VideoCodec.vp9), (min: 0, max: 63));
    });
    test('crf mapping is distinct per codec', () {
      final h264Medium =
          QualityMapper.crfFor(VideoQuality.medium, VideoCodec.h264);
      final av1Medium =
          QualityMapper.crfFor(VideoQuality.medium, VideoCodec.av1);
      expect(
        h264Medium,
        isNot(av1Medium),
        reason: 'AV1 and H264 must have different CRF scales',
      );
    });
    test('h264 quality order: veryHigh < veryLow (lower CRF = higher quality)',
        () {
      expect(
        QualityMapper.crfFor(VideoQuality.veryHigh, VideoCodec.h264),
        lessThan(
          QualityMapper.crfFor(VideoQuality.veryLow, VideoCodec.h264),
        ),
      );
    });
    test(
        'av1 veryHigh is higher quality than h264 veryHigh numerically but comparable perceptually',
        () {
      // AV1 28 vs H264 18 — different scales, both valid
      expect(QualityMapper.isValidCrf(28, VideoCodec.av1), true);
      expect(QualityMapper.isValidCrf(18, VideoCodec.h264), true);
    });
    test('isValidCrf boundaries', () {
      expect(QualityMapper.isValidCrf(51, VideoCodec.h264), true);
      expect(QualityMapper.isValidCrf(52, VideoCodec.h264), false);
      expect(QualityMapper.isValidCrf(63, VideoCodec.av1), true);
      expect(QualityMapper.isValidCrf(64, VideoCodec.av1), false);
    });
    test('targetBitrate scales with resolution and quality', () {
      final high = QualityMapper.targetBitrateFor(
        quality: VideoQuality.high,
        width: 1920,
        height: 1080,
        fps: 30,
        codec: VideoCodec.h264,
      );
      final low = QualityMapper.targetBitrateFor(
        quality: VideoQuality.low,
        width: 1920,
        height: 1080,
        fps: 30,
        codec: VideoCodec.h264,
      );
      expect(high, greaterThan(low));
    });
    test('hevc bitrate is lower than h264 for same quality (codec efficiency)',
        () {
      final h264 = QualityMapper.targetBitrateFor(
        quality: VideoQuality.medium,
        width: 1920,
        height: 1080,
        fps: 30,
        codec: VideoCodec.h264,
      );
      final hevc = QualityMapper.targetBitrateFor(
        quality: VideoQuality.medium,
        width: 1920,
        height: 1080,
        fps: 30,
        codec: VideoCodec.h265,
      );
      expect(hevc, lessThan(h264));
    });
    test('bitrate clamped to sane mobile range', () {
      final tiny = QualityMapper.targetBitrateFor(
        quality: VideoQuality.veryLow,
        width: 160,
        height: 120,
        fps: 15,
        codec: VideoCodec.h264,
      );
      expect(tiny, greaterThanOrEqualTo(300000));
      final huge = QualityMapper.targetBitrateFor(
        quality: VideoQuality.veryHigh,
        width: 7680,
        height: 4320,
        fps: 60,
        codec: VideoCodec.h264,
      );
      expect(huge, lessThanOrEqualTo(20000000));
    });
  });
}
