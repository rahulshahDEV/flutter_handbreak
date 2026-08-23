import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_handbreak/handbreak.dart';

MediaInfo _info({
  int w = 1920,
  int h = 1080,
  double fps = 30,
  String videoCodec = 'h264',
  String? audioCodec = 'aac',
  int audioBitrate = 128000,
  String path = '/tmp/in.mp4',
}) {
  return MediaInfo.fromMap({
    'path': path,
    'container': 'mp4',
    'durationMs': 10000,
    'fileSizeBytes': 5000000,
    'overallBitrate': 4000000,
    'videoStreams': [
      {
        'index': 0,
        'codec': videoCodec,
        'codecString': videoCodec,
        'width': w,
        'height': h,
        'rotation': 0,
        'frameRate': fps,
        'averageFrameRate': fps,
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
        'displayAspectRatio': h == 0 ? 0 : w / h,
        'sampleAspectRatio': 1.0,
      }
    ],
    if (audioCodec != null)
      'audioStreams': [
        {
          'index': 1,
          'codec': audioCodec,
          'codecString': audioCodec,
          'sampleRate': 44100,
          'channelCount': 2,
          'bitRate': audioBitrate,
        }
      ],
    'metadata': {},
  });
}

HardwareCapabilities _caps(
  String platform, {
  bool h264 = true,
  bool h265 = true,
  bool av1 = false,
}) {
  return HardwareCapabilities(
    supportsHardwareH264Encode: h264,
    supportsHardwareH265Encode: h265,
    supportsHardwareAv1Encode: av1,
    supportsHardwareVp9Encode: false,
    supportsHardwareDecode: true,
    platform: platform,
  );
}

void main() {
  group('EncodePlanResolver — dimensions', () {
    test('caps at maxWidth preserving aspect', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(w: 3840, h: 2160),
        opts: const VideoCompressionOptions(maxWidth: 1920),
        caps: _caps('android'),
      );
      expect(plan.width, 1920);
      expect(plan.height, 1080);
    });
    test('portrait stays portrait', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(w: 1080, h: 1920),
        opts: const VideoCompressionOptions(maxWidth: 720, maxHeight: 720),
        caps: _caps('ios'),
      );
      expect(plan.height > plan.width, isTrue);
    });
  });

  group('EncodePlanResolver — frame rate', () {
    test('sameAsSource with maxFrameRate below source → limitFrameRate', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(fps: 60),
        opts: const VideoCompressionOptions(maxFrameRate: 30),
        caps: _caps('android'),
      );
      expect(plan.targetFps, 30);
      expect(plan.limitFrameRate, isTrue);
    });
    test('sameAsSource with high maxFrameRate → no limiting', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(fps: 30),
        opts: const VideoCompressionOptions(maxFrameRate: 60),
        caps: _caps('android'),
      );
      expect(plan.limitFrameRate, isFalse);
      expect(plan.targetFps, 30);
    });
    test('variable mode never limits (VFR passthrough)', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(fps: 60),
        opts: const VideoCompressionOptions(
          frameRateMode: FrameRateMode.variable,
          maxFrameRate: 24,
        ),
        caps: _caps('android'),
      );
      expect(plan.limitFrameRate, isFalse);
    });
  });

  group('EncodePlanResolver — container fallback', () {
    test('mkv falls back to mp4 on android with note', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(),
        opts: const VideoCompressionOptions(container: VideoContainer.mkv),
        caps: _caps('android'),
      );
      expect(plan.containerId, 'mp4');
      expect(plan.containerFallbackNote, isNotNull);
    });
    test('mkv falls back to mp4 on ios with note', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(),
        opts: const VideoCompressionOptions(container: VideoContainer.mkv),
        caps: _caps('ios'),
      );
      expect(plan.containerId, 'mp4');
    });
    test('webm allowed on android only for vp9+opus', () {
      // vp9 requested but default aac audio → webm not allowed → mp4
      final p1 = EncodePlanResolver.resolve(
        info: _info(),
        opts: const VideoCompressionOptions(
          codec: VideoCodec.vp9,
          container: VideoContainer.mp4,
        ),
        caps: _caps('android'),
      );
      expect(p1.containerId, 'mp4');
    });
    test('mov honored on ios, falls back on android', () {
      final ios = EncodePlanResolver.resolve(
        info: _info(),
        opts: const VideoCompressionOptions(container: VideoContainer.mov),
        caps: _caps('ios'),
      );
      expect(ios.containerId, 'mov');
      expect(ios.containerFallbackNote, isNull);
      final android = EncodePlanResolver.resolve(
        info: _info(),
        opts: const VideoCompressionOptions(container: VideoContainer.mov),
        caps: _caps('android'),
      );
      expect(android.containerId, 'mp4');
      expect(android.containerFallbackNote, isNotNull);
    });
  });

  group('EncodePlanResolver — hardware policy', () {
    test('auto uses hw when available', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(),
        opts: const VideoCompressionOptions(),
        caps: _caps('android', h264: true),
      );
      expect(plan.useHardware, isTrue);
    });
    test('auto falls back to software with note when unavailable', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(),
        opts: const VideoCompressionOptions(),
        caps: _caps('android', h264: false),
      );
      expect(plan.useHardware, isFalse);
      expect(plan.hwFallbackNote, isNotNull);
    });
    test('hardwareOnly throws when unavailable', () {
      expect(
        () => EncodePlanResolver.resolve(
          info: _info(),
          opts: const VideoCompressionOptions(
            hardwareAcceleration: HardwareAcceleration.hardwareOnly,
          ),
          caps: _caps('android', h264: false),
        ),
        throwsA(isA<HardwareEncoderUnavailableException>()),
      );
    });
    test('softwareOnly forces software even when hw exists', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(),
        opts: const VideoCompressionOptions(
          hardwareAcceleration: HardwareAcceleration.softwareOnly,
        ),
        caps: _caps('android', h264: true),
      );
      expect(plan.useHardware, isFalse);
    });
  });

  group('EncodePlanResolver — rate control', () {
    test('discrete quality maps codec-aware CRF', () {
      final h264 = EncodePlanResolver.resolve(
        info: _info(),
        opts: const VideoCompressionOptions(
          rateControl: RateControl.constantQuality(VideoQuality.medium),
        ),
        caps: _caps('android'),
      );
      final av1 = EncodePlanResolver.resolve(
        info: _info(),
        opts: const VideoCompressionOptions(
          codec: VideoCodec.av1,
          rateControl: RateControl.constantQuality(VideoQuality.medium),
        ),
        caps: _caps('android'),
      );
      expect(
        h264.crf,
        QualityMapper.crfFor(VideoQuality.medium, VideoCodec.h264),
      );
      expect(
        av1.crf,
        QualityMapper.crfFor(VideoQuality.medium, VideoCodec.av1),
      );
      expect(h264.crf, isNot(av1.crf));
    });
    test('abr clamps bitrate', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(),
        opts: const VideoCompressionOptions(
          rateControl: RateControl.averageBitrate(10),
        ),
        caps: _caps('android'),
      );
      expect(plan.rateControlMode, 'abr');
      expect(plan.bitrateKbps, 64); // clamp floor
    });
    test('advanced.crf out of range throws', () {
      expect(
        () => EncodePlanResolver.resolve(
          info: _info(),
          opts: const VideoCompressionOptions(
            advanced: AdvancedEncoderOptions(crf: 99),
          ),
          caps: _caps('android'),
        ),
        throwsArgumentError,
      );
    });
    test('advanced.crf overrides quality mapping', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(),
        opts: const VideoCompressionOptions(
          rateControl: RateControl.constantQuality(VideoQuality.medium),
          advanced: AdvancedEncoderOptions(crf: 20),
        ),
        caps: _caps('android'),
      );
      expect(plan.crf, 20.0);
      expect(plan.rateControlMode, 'cq_value');
    });
  });

  group('EncodePlanResolver — audio plan', () {
    test('remove mode strips audio', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(),
        opts: const VideoCompressionOptions(
          audio: AudioOptions(mode: AudioMode.remove),
        ),
        caps: _caps('android'),
      );
      expect(plan.audio.mode, 'remove');
    });
    test('aac copy passthrough on android mp4', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(audioCodec: 'aac'),
        opts: const VideoCompressionOptions(
          audio: AudioOptions(mode: AudioMode.copy, codec: AudioCodec.copy),
        ),
        caps: _caps('android'),
      );
      expect(plan.audio.mode, 'passthrough');
      expect(plan.audio.codecId, 'aac');
    });
    test('opus copy into mp4 falls back to transcode+aac with note', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(audioCodec: 'opus'),
        opts: const VideoCompressionOptions(
          audio: AudioOptions(mode: AudioMode.copy, codec: AudioCodec.copy),
        ),
        caps: _caps('android'),
      );
      expect(plan.audio.mode, 'transcode');
      expect(plan.audio.codecId, 'aac');
      expect(plan.audio.note, isNotNull);
    });
    test('explicit opus encode on android mp4 → aac note', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(),
        opts: const VideoCompressionOptions(
          audio: AudioOptions(codec: AudioCodec.opus),
        ),
        caps: _caps('android'),
      );
      expect(plan.audio.codecId, 'aac');
      expect(plan.audio.note, contains('AAC'));
    });
  });

  group('canonicalizeFilters', () {
    test('orders stages canonically regardless of input order', () {
      final ordered = canonicalizeFilters([
        const DenoiseFilter(strength: DenoiseStrength.light),
        const ScaleFilter(width: 1280),
        const CropFilter(top: 2),
        const GrayscaleFilter(),
      ]);
      expect(
        ordered.map((f) => f['type']).toList(),
        ['crop', 'scale', 'denoise', 'grayscale'],
      );
    });
    test('later duplicate of same stage wins', () {
      final ordered = canonicalizeFilters([
        const CropFilter(top: 1),
        const CropFilter(bottom: 3),
      ]);
      expect(ordered.length, 1);
      expect(ordered.first['bottom'], 3);
    });
  });

  group('ResolvedPlan round-trip', () {
    test('toMap/fromMap preserves fields', () {
      final plan = EncodePlanResolver.resolve(
        info: _info(),
        opts: const VideoCompressionOptions(maxWidth: 1280, maxFrameRate: 30),
        caps: _caps('android'),
      );
      final rt = ResolvedPlan.fromMap(plan.toMap());
      expect(rt.width, plan.width);
      expect(rt.height, plan.height);
      expect(rt.containerId, plan.containerId);
      expect(rt.audio.mode, plan.audio.mode);
      expect(rt.limitFrameRate, plan.limitFrameRate);
    });
  });
}
