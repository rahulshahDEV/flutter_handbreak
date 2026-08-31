import '../hardware/hardware_acceleration.dart';
import 'filters.dart';
import 'frame_rate_mode.dart';
import 'rate_control.dart';
import 'video_codec.dart';

/// Advanced encoder knobs — codec-specific tuning without polluting the basic API.
/// Example: `AdvancedEncoderOptions(crf: 22, preset: 'slow', tune: 'film', extra: {'profile':'high'})`
class AdvancedEncoderOptions {
  const AdvancedEncoderOptions({
    this.crf,
    this.preset,
    this.tune,
    this.profile,
    this.level,
    this.extra = const {},
  });

  /// Explicit native CRF/QP numeric. If set, overrides [RateControl] quality mapping.
  final double? crf;
  final String? preset; // ultrafast..placebo / speed preset
  final String? tune; // film/animation/grain/psnr/ssim/fastdecode
  final String? profile;
  final String? level;
  final Map<String, String> extra;

  Map<String, dynamic> toMap() => {
        if (crf != null) 'crf': crf,
        if (preset != null) 'preset': preset,
        if (tune != null) 'tune': tune,
        if (profile != null) 'profile': profile,
        if (level != null) 'level': level,
        'extra': extra,
      };
}

class AudioOptions {
  const AudioOptions({
    this.mode = AudioMode.encode,
    this.codec = AudioCodec.aac,
    this.bitrateKbps = 128,
    this.sampleRate,
    this.mixdown = 'stereo',
  });

  final AudioMode mode;
  final AudioCodec codec;
  final int bitrateKbps;
  final int? sampleRate;
  final String
      mixdown; // stereo / mono / 5point1 etc. Dart validates known values; native may ignore unsupported.

  Map<String, dynamic> toMap() => {
        'mode': mode.name,
        'codec': codec.id,
        'bitrateKbps': bitrateKbps,
        if (sampleRate != null) 'sampleRate': sampleRate,
        'mixdown': mixdown,
      };
}

class VideoCompressionOptions {
  const VideoCompressionOptions({
    this.codec = VideoCodec.h264,
    this.container = VideoContainer.mp4,
    this.rateControl = const RateControl.constantQuality(VideoQuality.medium),
    this.quality,
    this.maxWidth,
    this.maxHeight,
    this.targetWidth,
    this.targetHeight,
    this.scale,
    this.preserveAspectRatio = true,
    this.allowStretch = false,
    this.preserveResolution = false,
    this.frameRateMode = FrameRateMode.sameAsSource,
    this.maxFrameRate,
    this.constantFrameRate,
    this.audio = const AudioOptions(),
    this.hardwareAcceleration = HardwareAcceleration.auto,
    this.filters = const [],
    this.advanced = const AdvancedEncoderOptions(),
    this.tempoScale = 1.0,
    this.keepOriginalIfSmaller = false,
    this.overwriteExisting = false,
    this.presetName,
  });

  /// @deprecated Use [rateControl]. Kept for ergonomics.
  final VideoQuality? quality;

  final VideoCodec codec;
  final VideoContainer container;
  final RateControl rateControl;

  // Resolution management — mirrors HandBrake's PictureWidth/Height + KeepRatio + modulus
  final int? maxWidth;
  final int? maxHeight;
  final int? targetWidth;
  final int? targetHeight;
  final double? scale; // 0.5 = half resolution
  final bool preserveAspectRatio;
  final bool allowStretch;

  /// HandBrake-style "same as source": compress at the source resolution.
  /// Overrides [maxWidth]/[maxHeight]/[targetWidth]/[targetHeight]/[scale]
  /// — size-preserving compression only.
  final bool preserveResolution;

  // Frame rate — mirrors job->vrate + cfr flag + correct_framerate logic
  final FrameRateMode frameRateMode;
  final double? maxFrameRate;
  final bool? constantFrameRate; // alias for legacy callers

  final AudioOptions audio;
  final HardwareAcceleration hardwareAcceleration;
  final List<VideoFilter> filters;
  final AdvancedEncoderOptions advanced;

  /// Playback speed multiplier (future: time-stretch filter). 1.0 = unchanged.
  final double tempoScale;

  /// If compressed output would be larger than source, return original (or keep smaller).
  final bool keepOriginalIfSmaller;

  /// Overwrite the destination file if it already exists. Default false →
  /// throws OutputCreationException when the destination exists.
  final bool overwriteExisting;

  /// Tag for analytics/presets — not sent to native encoder.
  final String? presetName;

  RateControl get effectiveRateControl =>
      quality != null ? RateControl.constantQuality(quality!) : rateControl;

  void validate() {
    if (maxWidth != null && maxWidth! <= 0) {
      throw ArgumentError('maxWidth must be > 0');
    }
    if (maxHeight != null && maxHeight! <= 0) {
      throw ArgumentError('maxHeight must be > 0');
    }
    if (targetWidth != null && targetWidth! <= 0) {
      throw ArgumentError('targetWidth must be > 0');
    }
    if (targetHeight != null && targetHeight! <= 0) {
      throw ArgumentError('targetHeight must be > 0');
    }
    if (scale != null && (scale! <= 0 || scale! > 4)) {
      throw ArgumentError('scale must be (0, 4]');
    }
    if (maxFrameRate != null && maxFrameRate! <= 0) {
      throw ArgumentError('maxFrameRate must be > 0');
    }
    if (tempoScale <= 0 || tempoScale > 8) {
      throw ArgumentError('tempoScale must be (0, 8]');
    }
  }

  VideoCompressionOptions copyWith({
    VideoCodec? codec,
    VideoContainer? container,
    RateControl? rateControl,
    VideoQuality? quality,
    int? maxWidth,
    int? maxHeight,
    int? targetWidth,
    int? targetHeight,
    double? scale,
    bool? preserveAspectRatio,
    bool? allowStretch,
    bool? preserveResolution,
    FrameRateMode? frameRateMode,
    double? maxFrameRate,
    AudioOptions? audio,
    HardwareAcceleration? hardwareAcceleration,
    List<VideoFilter>? filters,
    AdvancedEncoderOptions? advanced,
  }) =>
      VideoCompressionOptions(
        codec: codec ?? this.codec,
        container: container ?? this.container,
        rateControl: rateControl ?? this.rateControl,
        quality: quality ?? this.quality,
        maxWidth: maxWidth ?? this.maxWidth,
        maxHeight: maxHeight ?? this.maxHeight,
        targetWidth: targetWidth ?? this.targetWidth,
        targetHeight: targetHeight ?? this.targetHeight,
        scale: scale ?? this.scale,
        preserveAspectRatio: preserveAspectRatio ?? this.preserveAspectRatio,
        allowStretch: allowStretch ?? this.allowStretch,
        preserveResolution: preserveResolution ?? this.preserveResolution,
        frameRateMode: frameRateMode ?? this.frameRateMode,
        maxFrameRate: maxFrameRate ?? this.maxFrameRate,
        audio: audio ?? this.audio,
        hardwareAcceleration: hardwareAcceleration ?? this.hardwareAcceleration,
        filters: filters ?? this.filters,
        advanced: advanced ?? this.advanced,
      );

  Map<String, dynamic> toMap() => {
        'codec': codec.id,
        'container': container.id,
        'rateControl': effectiveRateControl.toMap(),
        if (maxWidth != null) 'maxWidth': maxWidth,
        if (maxHeight != null) 'maxHeight': maxHeight,
        if (targetWidth != null) 'targetWidth': targetWidth,
        if (targetHeight != null) 'targetHeight': targetHeight,
        if (scale != null) 'scale': scale,
        'preserveAspectRatio': preserveAspectRatio,
        'allowStretch': allowStretch,
        'preserveResolution': preserveResolution,
        'frameRateMode': frameRateMode.name,
        if (maxFrameRate != null) 'maxFrameRate': maxFrameRate,
        if (constantFrameRate != null) 'constantFrameRate': constantFrameRate,
        'audio': audio.toMap(),
        'hardwareAcceleration': hardwareAcceleration.name,
        'filters': filters.map((f) => f.toMap()).toList(),
        'advanced': advanced.toMap(),
        'keepOriginalIfSmaller': keepOriginalIfSmaller,
        'overwriteExisting': overwriteExisting,
        if (presetName != null) 'presetName': presetName,
      };
}
