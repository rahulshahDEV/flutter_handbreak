import '../video/rate_control.dart';
import '../video/video_codec.dart';

/// Codec-aware quality mapping.
/// HandBrake's lesson: lower number can mean higher quality depending on codec.
/// Each codec has its own valid CRF/QP range; we map discrete [VideoQuality] → native value.
class QualityMapper {
  const QualityMapper._();

  /// Valid inclusive range for the numeric CQ value per codec.
  /// These mirror the encoder presets: x264 0..51, x265 0..51, VP9 0..63, AV1 0..63, MediaCodec QP 0..51 etc.
  static ({double min, double max}) validRangeFor(VideoCodec codec) {
    switch (codec) {
      case VideoCodec.h264:
        return (min: 0, max: 51); // x264 CRF 0(lossless)..51(worst)
      case VideoCodec.h265:
        return (min: 0, max: 51); // x265 CRF
      case VideoCodec.av1:
        return (min: 0, max: 63); // AV1 CQ / libaom cq-level
      case VideoCodec.vp9:
        return (min: 0, max: 63); // VP9 CQ
    }
  }

  /// Map discrete quality → codec-specific CQ numeric.
  /// Defaults are chosen for *perceptual quality-first* mobile encodes (like HandBrake's sane defaults).
  static double crfFor(VideoQuality quality, VideoCodec codec) {
    // Base is H.264 CRF; other codecs offset because their curves differ.
    switch (codec) {
      case VideoCodec.h264:
        return switch (quality) {
          VideoQuality.veryHigh => 18,
          VideoQuality.high => 20,
          VideoQuality.medium => 23,
          VideoQuality.low => 26,
          VideoQuality.veryLow => 30,
        };
      case VideoCodec.h265:
        // x265's CRF curve is slightly steeper; 2 points lower gives comparable perceptual quality
        return switch (quality) {
          VideoQuality.veryHigh => 20,
          VideoQuality.high => 22,
          VideoQuality.medium => 25,
          VideoQuality.low => 28,
          VideoQuality.veryLow => 32,
        };
      case VideoCodec.av1:
        return switch (quality) {
          VideoQuality.veryHigh => 28,
          VideoQuality.high => 32,
          VideoQuality.medium => 38,
          VideoQuality.low => 44,
          VideoQuality.veryLow => 50,
        };
      case VideoCodec.vp9:
        return switch (quality) {
          VideoQuality.veryHigh => 30,
          VideoQuality.high => 34,
          VideoQuality.medium => 40,
          VideoQuality.low => 46,
          VideoQuality.veryLow => 52,
        };
    }
  }

  /// Android MediaCodec bitrate-mode mapping for ABR target.
  /// When using CQ on MediaCodec we drive via `KEY_QUALITY`/`CRF` shim where available; else fallback to VBR.
  static int targetBitrateFor({
    required VideoQuality quality,
    required int width,
    required int height,
    required double fps,
    required VideoCodec codec,
  }) {
    // Estimate bpp (bits per pixel per frame) from quality — avoids arbitrary bitrate lists.
    final bpp = switch (quality) {
      VideoQuality.veryHigh => 0.14,
      VideoQuality.high => 0.10,
      VideoQuality.medium => 0.07,
      VideoQuality.low => 0.045,
      VideoQuality.veryLow => 0.025,
    };
    // AV1 ~30% more efficient than H.264 at same perceptual quality; H.265 ~25%.
    final codecFactor = switch (codec) {
      VideoCodec.h264 => 1.0,
      VideoCodec.h265 => 0.75,
      VideoCodec.av1 => 0.70,
      VideoCodec.vp9 => 0.78,
    };
    final raw = (width * height * fps * bpp * codecFactor).round();
    // clamp to sane mobile range 300kbps .. 20Mbps
    return raw.clamp(300000, 20000000);
  }

  static bool isValidCrf(double value, VideoCodec codec) {
    final r = validRangeFor(codec);
    return value >= r.min && value <= r.max;
  }
}
