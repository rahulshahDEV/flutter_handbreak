import '../errors/handbreak_exception.dart';
import '../hardware/hardware_acceleration.dart';
import '../hardware/hardware_capabilities.dart';
import '../models/media_info.dart';
import '../utils/quality_mapper.dart';
import 'filters.dart';
import 'frame_rate_mode.dart';
import 'rate_control.dart';
import 'video_codec.dart';
import 'video_compression_options.dart';

/// Effective audio execution plan after fallback resolution.
class ResolvedAudioPlan {
  const ResolvedAudioPlan({
    required this.mode,
    required this.codecId,
    required this.bitrateKbps,
    this.note,
  });

  /// passthrough | transcode | remove
  final String mode;
  final String codecId;
  final int bitrateKbps;

  /// Human-readable note when a fallback occurred (surfaced via qualityWarning).
  final String? note;

  Map<String, dynamic> toMap() => {
        'mode': mode,
        'codec': codecId,
        'bitrateKbps': bitrateKbps,
        if (note != null) 'note': note,
      };

  factory ResolvedAudioPlan.fromMap(Map<String, dynamic> m) =>
      ResolvedAudioPlan(
        mode: m['mode'] as String? ?? 'transcode',
        codecId: m['codec'] as String? ?? 'aac',
        bitrateKbps: m['bitrateKbps'] as int? ?? 128,
        note: m['note'] as String?,
      );
}

/// Fully-resolved, native-executable encode plan.
///
/// Produced by [EncodePlanResolver] — the single source of truth for policy
/// (dimensions, fps gate, container fallback, rate control, hardware choice,
/// audio plan, filter order). Natives execute this plan; they never re-derive
/// heuristics. This mirrors HandBrake's `sanitize_*` + `correct_framerate`
/// phase where the job config is finalized before `do_job` builds the pipeline.
class ResolvedPlan {
  const ResolvedPlan({
    required this.width,
    required this.height,
    required this.sourceFps,
    required this.targetFps,
    required this.limitFrameRate,
    required this.containerId,
    required this.useHardware,
    required this.rateControlMode,
    required this.audio,
    required this.orderedFilters,
    this.crf,
    this.bitrateKbps,
    this.containerFallbackNote,
    this.hwFallbackNote,
  });

  final int width;
  final int height;

  final double sourceFps;
  final double targetFps;

  /// True when target < source → decoder-output PTS gate drops frames (never duplicates).
  final bool limitFrameRate;

  /// Effective container id after muxer-support fallback (mp4|mov|webm).
  final String containerId;
  final String? containerFallbackNote;

  final bool useHardware;
  final String? hwFallbackNote;

  /// cq | cq_value | abr
  final String rateControlMode;
  final double? crf;
  final int? bitrateKbps;

  final ResolvedAudioPlan audio;
  final List<Map<String, dynamic>> orderedFilters;

  Map<String, dynamic> toMap() => {
        'width': width,
        'height': height,
        'sourceFps': sourceFps,
        'targetFps': targetFps,
        'limitFrameRate': limitFrameRate,
        'container': containerId,
        if (containerFallbackNote != null)
          'containerFallbackNote': containerFallbackNote,
        'useHardware': useHardware,
        if (hwFallbackNote != null) 'hwFallbackNote': hwFallbackNote,
        'rateControlMode': rateControlMode,
        if (crf != null) 'crf': crf,
        if (bitrateKbps != null) 'bitrateKbps': bitrateKbps,
        'audio': audio.toMap(),
        'filters': orderedFilters,
      };

  static ResolvedPlan fromMap(Map<String, dynamic> m) => ResolvedPlan(
        width: m['width'] as int? ?? 0,
        height: m['height'] as int? ?? 0,
        sourceFps: (m['sourceFps'] as num?)?.toDouble() ?? 30,
        targetFps: (m['targetFps'] as num?)?.toDouble() ?? 30,
        limitFrameRate: m['limitFrameRate'] as bool? ?? false,
        containerId: m['container'] as String? ?? 'mp4',
        containerFallbackNote: m['containerFallbackNote'] as String?,
        useHardware: m['useHardware'] as bool? ?? false,
        hwFallbackNote: m['hwFallbackNote'] as String?,
        rateControlMode: m['rateControlMode'] as String? ?? 'cq',
        crf: (m['crf'] as num?)?.toDouble(),
        bitrateKbps: m['bitrateKbps'] as int?,
        audio: ResolvedAudioPlan.fromMap(
          Map<String, dynamic>.from(m['audio'] as Map? ?? {}),
        ),
        orderedFilters: ((m['filters'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      );
}

/// Muxer reality per platform — what containers can actually be written.
/// Android MediaMuxer: MPEG_4, WEBM (VP8/VP9 + Opus/Vorbis), 3GP(h263), OGG(Opus API29+).
/// iOS AVAssetExportSession: mp4/mov/m4v only.
class ContainerSupport {
  const ContainerSupport._();

  static bool platformSupports(String platform, String container) {
    switch (platform) {
      case 'android':
        return container == 'mp4' || container == 'webm' || container == '3gp';
      case 'ios':
        return container == 'mp4' || container == 'mov';
      default:
        return container == 'mp4';
    }
  }

  /// Codec-level compatibility beyond container presence.
  static bool codecFits(
    String container,
    String videoCodecId, {
    String? audioCodecId,
  }) {
    switch (container) {
      case 'mp4':
      case 'mov':
        return true; // h264/h265/av1/vp9 all legal in ISO-BMFF
      case 'webm':
        // WebM requires VP8/VP9 video and Opus/Vorbis audio.
        if (videoCodecId != 'vp9') return false;
        if (audioCodecId == null || audioCodecId == 'none') return true;
        return audioCodecId == 'opus';
      case '3gp':
        return videoCodecId == 'h264'; // conservative
      default:
        return false;
    }
  }
}

/// Canonical filter order mirroring HandBrake's sanitize_filter_list_pre/post:
/// crop → scale → pad → rotate → deinterlace → denoise → sharpen → grayscale
const List<String> kCanonicalFilterOrder = [
  'crop',
  'scale',
  'pad',
  'rotate',
  'deinterlace',
  'denoise',
  'sharpen',
  'grayscale',
];

List<Map<String, dynamic>> canonicalizeFilters(List<VideoFilter> filters) {
  final byType = <String, Map<String, dynamic>>{};
  for (final f in filters) {
    final m = f.toMap();
    byType[m['type'] as String] =
        m; // later entries win per stage (like HB disabling dupes)
  }
  return [
    for (final t in kCanonicalFilterOrder)
      if (byType[t] != null) byType[t]!,
  ];
}

/// Audio codecs that can be bit-copied into MP4-family containers on Android.
const Set<String> kAndroidMp4CopyableAudio = {'aac', 'mp3', 'ac3', 'eac3'};

/// iOS ExportSession re-encodes regardless; treat copy conservatively.
const Set<String> kIosCopyableAudio = {'aac'};

class EncodePlanResolver {
  const EncodePlanResolver._();

  /// Resolve everything needed for a deterministic native execution.
  ///
  /// Throws:
  /// - [HardwareEncoderUnavailableException] when `hardwareOnly` requested but unavailable.
  /// - [UnsupportedFormatException] when neither requested nor fallback containers fit.
  static ResolvedPlan resolve({
    required MediaInfo info,
    required VideoCompressionOptions opts,
    required HardwareCapabilities caps,
  }) {
    final v = info.primaryVideo;
    final srcW = v?.width ?? 0;
    final srcH = v?.height ?? 0;
    if (srcW <= 0 || srcH <= 0) {
      throw UnsupportedFormatException(
        'No decodable video stream in ${info.path}',
      );
    }

    // ---- dimensions -------------------------------------------------------
    final size = _resolveDimensions(
      srcWidth: srcW,
      srcHeight: srcH,
      maxWidth: opts.maxWidth,
      maxHeight: opts.maxHeight,
      targetWidth: opts.targetWidth,
      targetHeight: opts.targetHeight,
      scale: opts.scale,
      preserveAspectRatio: opts.preserveAspectRatio,
      allowStretch: opts.allowStretch,
    );

    // ---- frame rate -------------------------------------------------------
    var srcFps = v!.averageFrameRate > 0 ? v.averageFrameRate : v.frameRate;
    if (srcFps <= 0) srcFps = 30;
    double targetFps;
    switch (opts.frameRateMode) {
      case FrameRateMode.variable:
        targetFps = srcFps; // passthrough timestamps untouched
      case FrameRateMode.constant:
        targetFps = opts.maxFrameRate != null && opts.maxFrameRate! < srcFps
            ? opts.maxFrameRate!
            : srcFps;
      case FrameRateMode.sameAsSource:
        targetFps = opts.maxFrameRate != null && opts.maxFrameRate! < srcFps
            ? opts.maxFrameRate!
            : srcFps;
    }
    final limitFrameRate = targetFps < srcFps - 0.01;

    // ---- container fallback ----------------------------------------------
    final requestedContainer = opts.container.id;
    String effectiveContainer = requestedContainer;
    String? containerNote;
    bool fits(String c) =>
        ContainerSupport.platformSupports(caps.platform, c) &&
        ContainerSupport.codecFits(
          c,
          opts.codec.id,
          audioCodecId: _effectiveAudioForContainer(opts.audio.codec.id),
        );
    if (!fits(effectiveContainer)) {
      for (final fb in const ['mp4', 'mov']) {
        if (fb != effectiveContainer && fits(fb)) {
          containerNote =
              'Container "$requestedContainer" not supported by ${caps.platform} muxer for this codec combination; fell back to "$fb".';
          effectiveContainer = fb;
          break;
        }
      }
      if (!fits(effectiveContainer)) {
        throw UnsupportedFormatException(
          'No supported container on ${caps.platform} for ${opts.codec.id}',
        );
      }
    }

    // ---- audio plan -------------------------------------------------------
    final audio = _resolveAudio(info, opts, effectiveContainer, caps.platform);

    // ---- hardware decision ------------------------------------------------
    final hwRequested =
        opts.hardwareAcceleration != HardwareAcceleration.softwareOnly;
    final hwAvailable = caps.supportsEncodeFor(opts.codec.id);
    bool useHardware;
    String? hwNote;
    switch (opts.hardwareAcceleration) {
      case HardwareAcceleration.softwareOnly:
        useHardware = false;
      case HardwareAcceleration.hardwareOnly:
        if (!hwAvailable) {
          throw HardwareEncoderUnavailableException(
            'hardwareOnly requested but no hardware encoder for ${opts.codec.id} on ${caps.platform}',
          );
        }
        useHardware = true;
      case HardwareAcceleration.auto:
      case HardwareAcceleration.hardwarePreferred:
        useHardware = hwAvailable;
        if (!hwAvailable && hwRequested) {
          hwNote =
              'Hardware ${opts.codec.id} encoder unavailable on this device; using software.';
        }
    }

    // ---- rate control -----------------------------------------------------
    String rcMode;
    double? crf;
    int? bitrateKbps;
    final effRc = opts.effectiveRateControl;
    switch (effRc) {
      case ConstantQualityRateControl():
        rcMode = 'cq';
        crf = QualityMapper.crfFor(effRc.quality, opts.codec);
      case ConstantQualityValueRateControl():
        if (!QualityMapper.isValidCrf(effRc.value, opts.codec)) {
          throw ArgumentError(
            'CRF ${effRc.value} outside valid range ${QualityMapper.validRangeFor(opts.codec)} for ${opts.codec.id}',
          );
        }
        rcMode = 'cq_value';
        crf = effRc.value;
      case AverageBitrateRateControl():
        rcMode = 'abr';
        bitrateKbps = effRc.bitrateKbps.clamp(64, 100000);
    }
    final advCrf = opts.advanced.crf;
    if (advCrf != null) {
      if (!QualityMapper.isValidCrf(advCrf, opts.codec)) {
        throw ArgumentError(
          'advanced.crf $advCrf outside valid range for ${opts.codec.id}',
        );
      }
      rcMode = 'cq_value';
      crf = advCrf;
      bitrateKbps = null;
    }

    return ResolvedPlan(
      width: size.width,
      height: size.height,
      sourceFps: srcFps,
      targetFps: targetFps,
      limitFrameRate: limitFrameRate,
      containerId: effectiveContainer,
      containerFallbackNote: containerNote,
      useHardware: useHardware,
      hwFallbackNote: hwNote,
      rateControlMode: rcMode,
      crf: crf,
      bitrateKbps: bitrateKbps,
      audio: audio,
      orderedFilters: canonicalizeFilters(opts.filters),
    );
  }

  static ({int width, int height}) _resolveDimensions({
    required int srcWidth,
    required int srcHeight,
    int? maxWidth,
    int? maxHeight,
    int? targetWidth,
    int? targetHeight,
    double? scale,
    required bool preserveAspectRatio,
    required bool allowStretch,
  }) {
    final aspect = srcWidth / srcHeight;
    int w = srcWidth;
    int h = srcHeight;
    if (targetWidth != null || targetHeight != null) {
      if (!preserveAspectRatio || allowStretch) {
        w = targetWidth ?? ((targetHeight! * aspect).round());
        h = targetHeight ?? ((targetWidth! / aspect).round());
      } else {
        if (targetWidth != null && targetHeight != null) {
          final ta = targetWidth / targetHeight;
          if (aspect > ta) {
            w = targetWidth;
            h = (w / aspect).round();
          } else {
            h = targetHeight;
            w = (h * aspect).round();
          }
        } else if (targetWidth != null) {
          w = targetWidth;
          h = (w / aspect).round();
        } else {
          h = targetHeight!;
          w = (h * aspect).round();
        }
      }
    } else if (scale != null) {
      w = (srcWidth * scale).round();
      h = (srcHeight * scale).round();
    } else {
      if (maxWidth != null && w > maxWidth) {
        w = maxWidth;
        h = (w / aspect).round();
      }
      if (maxHeight != null && h > maxHeight) {
        h = maxHeight;
        w = (h * aspect).round();
      }
    }
    w = _align(w);
    h = _align(h);
    w = w.clamp(2, 7680);
    h = h.clamp(2, 7680);
    final explicit =
        targetWidth != null || targetHeight != null || scale != null;
    if (!explicit && (w > srcWidth || h > srcHeight)) {
      w = _align(srcWidth);
      h = _align(srcHeight);
    }
    return (width: w, height: h);
  }

  static int _align(int v) => ((v + 1) ~/ 2) * 2;

  static String? _effectiveAudioForContainer(String requestedAudioCodec) {
    return requestedAudioCodec == 'copy' ? null : requestedAudioCodec;
  }

  static ResolvedAudioPlan _resolveAudio(
    MediaInfo info,
    VideoCompressionOptions opts,
    String effectiveContainer,
    String platform,
  ) {
    final userAudio = opts.audio;
    if (userAudio.mode == AudioMode.remove) {
      return const ResolvedAudioPlan(
        mode: 'remove',
        codecId: 'none',
        bitrateKbps: 0,
      );
    }

    final srcAudio = info.primaryAudio;
    final srcCodec = srcAudio?.codec.toLowerCase();

    // copy requested (or archive preset default): passthrough when safe
    if (userAudio.mode == AudioMode.copy ||
        (userAudio.codec == AudioCodec.copy && srcCodec != null)) {
      final requested =
          userAudio.codec == AudioCodec.copy ? srcCodec! : userAudio.codec.id;
      final copyable =
          platform == 'ios' ? kIosCopyableAudio : kAndroidMp4CopyableAudio;
      final containerAllows =
          effectiveContainer == 'mp4' || effectiveContainer == 'mov';
      if (containerAllows && copyable.contains(requested) && srcAudio != null) {
        return ResolvedAudioPlan(
          mode: 'passthrough',
          codecId: requested,
          bitrateKbps: srcAudio.bitRate > 0
              ? (srcAudio.bitRate / 1000).round()
              : userAudio.bitrateKbps,
        );
      }
      // fall through to transcode with note when unsafe
      final note = requested == 'opus' &&
              platform == 'android' &&
              effectiveContainer == 'mp4'
          ? 'Opus copy into MP4 is unreliable on Android MediaMuxer; transcoding to AAC.'
          : (srcAudio == null
              ? null
              : 'Source audio ($requested) cannot be safely copied; transcoding.');
      final target =
          userAudio.codec == AudioCodec.opus && effectiveContainer == 'webm'
              ? 'opus'
              : 'aac';
      return ResolvedAudioPlan(
        mode: 'transcode',
        codecId: target,
        bitrateKbps: userAudio.bitrateKbps,
        note: note,
      );
    }

    // explicit encode request
    var targetCodec = userAudio.codec.id;
    String? note;
    if (targetCodec == 'opus' && !(effectiveContainer == 'webm')) {
      if (platform == 'android') {
        targetCodec = 'aac';
        note = 'Opus in $effectiveContainer unsupported on Android; using AAC.';
      }
      // iOS: ExportSession always emits AAC anyway; keep requested but note.
      else if (platform == 'ios') {
        targetCodec = 'aac';
        note = 'iOS export pipeline emits AAC; opus request mapped to AAC.';
      }
    }
    if (targetCodec == 'copy') targetCodec = 'aac'; // defensive
    return ResolvedAudioPlan(
      mode: 'transcode',
      codecId: targetCodec,
      bitrateKbps: userAudio.bitrateKbps,
      note: note,
    );
  }
}

/// Small helper so callers without full MediaInfo can still resolve image jobs consistently.
class ImagePlanTokens {
  const ImagePlanTokens._();
  static String resolveFormat(
    String requested, {
    required bool hasAlpha,
    required String platform,
  }) {
    if (requested != 'auto') return requested;
    if (!hasAlpha) return 'jpeg';
    // PNG universally safe for alpha; HEIC only when iOS.
    return platform == 'ios' ? 'png' : 'png';
  }
}
