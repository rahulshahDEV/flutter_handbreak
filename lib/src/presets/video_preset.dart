import '../hardware/hardware_acceleration.dart';
import '../video/frame_rate_mode.dart';
import '../video/rate_control.dart';
import '../video/video_codec.dart';
import '../video/video_compression_options.dart';

/// Presets — conceptual analogues of HandBrake's built-ins, but tuned for mobile.
/// Each preset maps to {codec, container, quality, max resolution, max fps, audio, hw policy}.
enum VideoPresetId {
  fast,
  balanced,
  highQuality,
  smallFile,
  socialMedia,
  messaging,
  web,
  archive,
}

extension VideoPreset on VideoPresetId {
  /// Resolve preset → concrete options. Caller may override individual fields afterwards via copyWith.
  VideoCompressionOptions toOptions({VideoCodec? codecOverride}) {
    switch (this) {
      case VideoPresetId.fast:
        return VideoCompressionOptions(
          codec: codecOverride ?? VideoCodec.h264,
          container: VideoContainer.mp4,
          rateControl: const RateControl.constantQuality(VideoQuality.low),
          maxWidth: 1280,
          maxHeight: 720,
          frameRateMode: FrameRateMode.sameAsSource,
          maxFrameRate: 30,
          audio: const AudioOptions(bitrateKbps: 96),
          hardwareAcceleration: HardwareAcceleration.hardwarePreferred,
          presetName: name,
        );
      case VideoPresetId.balanced:
        return VideoCompressionOptions(
          codec: codecOverride ?? VideoCodec.h264,
          container: VideoContainer.mp4,
          rateControl: const RateControl.constantQuality(VideoQuality.medium),
          maxWidth: 1920,
          maxHeight: 1080,
          frameRateMode: FrameRateMode.sameAsSource,
          maxFrameRate: 30,
          audio: const AudioOptions(bitrateKbps: 128),
          hardwareAcceleration: HardwareAcceleration.auto,
          presetName: name,
        );
      case VideoPresetId.highQuality:
        return VideoCompressionOptions(
          codec: codecOverride ?? VideoCodec.h264,
          container: VideoContainer.mp4,
          rateControl: const RateControl.constantQuality(VideoQuality.high),
          maxWidth: 1920,
          maxHeight: 1080,
          frameRateMode: FrameRateMode.sameAsSource,
          audio: const AudioOptions(bitrateKbps: 160),
          hardwareAcceleration: HardwareAcceleration.auto,
          presetName: name,
        );
      case VideoPresetId.smallFile:
        return VideoCompressionOptions(
          codec: codecOverride ?? VideoCodec.h265,
          container: VideoContainer.mp4,
          rateControl: const RateControl.constantQuality(VideoQuality.low),
          maxWidth: 1280,
          maxHeight: 720,
          frameRateMode: FrameRateMode.sameAsSource,
          maxFrameRate: 30,
          audio: const AudioOptions(bitrateKbps: 96),
          hardwareAcceleration: HardwareAcceleration.auto,
          presetName: name,
        );
      case VideoPresetId.socialMedia:
        // social platforms re-encode; 1080p/30 + AAC stereo @128 is the sweet spot
        return VideoCompressionOptions(
          codec: VideoCodec.h264, // always H.264 for broad compatibility
          container: VideoContainer.mp4,
          rateControl: const RateControl.constantQuality(VideoQuality.medium),
          maxWidth: 1080,
          maxHeight: 1920, // allow portrait (HandBrake keeps portrait via rotation-corrected geometry)
          frameRateMode: FrameRateMode.sameAsSource,
          maxFrameRate: 30,
          audio: const AudioOptions(bitrateKbps: 128, mixdown: 'stereo'),
          hardwareAcceleration: HardwareAcceleration.hardwarePreferred,
          presetName: name,
        );
      case VideoPresetId.messaging:
        // aggressive size reduction; still intelligible
        return VideoCompressionOptions(
          codec: VideoCodec.h264,
          container: VideoContainer.mp4,
          rateControl: const RateControl.constantQuality(VideoQuality.low),
          maxWidth: 720,
          maxHeight: 720,
          frameRateMode: FrameRateMode.sameAsSource,
          maxFrameRate: 30,
          audio: const AudioOptions(bitrateKbps: 64, mixdown: 'mono'),
          hardwareAcceleration: HardwareAcceleration.hardwarePreferred,
          presetName: name,
        );
      case VideoPresetId.web:
        // modern web: HEVC where possible, else H.264
        return VideoCompressionOptions(
          codec: codecOverride ?? VideoCodec.h265,
          container: VideoContainer.mp4,
          rateControl: const RateControl.constantQuality(VideoQuality.medium),
          maxWidth: 1920,
          maxHeight: 1080,
          frameRateMode: FrameRateMode.sameAsSource,
          audio: const AudioOptions(codec: AudioCodec.aac, bitrateKbps: 128),
          hardwareAcceleration: HardwareAcceleration.auto,
          presetName: name,
        );
      case VideoPresetId.archive:
        // preserve quality, allow 4K
        return VideoCompressionOptions(
          codec: codecOverride ?? VideoCodec.h265,
          container: VideoContainer.mkv,
          rateControl: const RateControl.constantQuality(VideoQuality.veryHigh),
          // no maxWidth/maxHeight — keep source resolution
          frameRateMode: FrameRateMode.sameAsSource,
          audio: const AudioOptions(mode: AudioMode.copy),
          hardwareAcceleration: HardwareAcceleration.auto,
          presetName: name,
        );
    }
  }

  String get displayName => switch (this) {
        VideoPresetId.fast => 'Fast (720p)',
        VideoPresetId.balanced => 'Balanced (1080p)',
        VideoPresetId.highQuality => 'High Quality (1080p)',
        VideoPresetId.smallFile => 'Small File (HEVC 720p)',
        VideoPresetId.socialMedia => 'Social Media (1080×1920, 30fps)',
        VideoPresetId.messaging => 'Messaging (720, mono)',
        VideoPresetId.web => 'Web (HEVC 1080p)',
        VideoPresetId.archive => 'Archive (preserve, 4K, passthrough audio)',
      };

  String get description => switch (this) {
        VideoPresetId.fast => 'Quick encode, hardware preferred. Good for previews.',
        VideoPresetId.balanced => 'Default quality-first mobile preset. H.264, MP4, up to 1080p30.',
        VideoPresetId.highQuality => 'Higher bitrate/CQ, keeps 1080p, AAC 160k.',
        VideoPresetId.smallFile => 'HEVC for ~40% smaller than H.264 at similar quality.',
        VideoPresetId.socialMedia => 'H.264 MP4 up to 1080×1920 @30fps, AAC stereo — safe for Instagram/TikTok.',
        VideoPresetId.messaging => 'Aggressive downscale to 720², mono audio — minimal bytes.',
        VideoPresetId.web => 'HEVC/AAC 128k. Use H.264 override for legacy browsers.',
        VideoPresetId.archive => 'Near-lossless, MKV, preserves resolution & audio.',
      };
}

/// Legacy alias so callers can write `VideoPreset.balanced` like the spec example.
typedef VideoPresetAlias = VideoPresetId;
