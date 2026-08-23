import 'dart:math' as math;

/// Pure, heavily-tested resolution math — mirrors HandBrake's
/// picture sizing (sanitize_filter_list_pre/post + hb_geometry_t handling).
///
/// Preserves aspect, respects rotation, snaps to even dimensions (modulus 2).
class ResolutionCalculator {
  const ResolutionCalculator._();

  /// Compute output dimensions from source + constraints.
  /// [srcWidth]/[srcHeight] are **rotation-corrected** (like job->width/height after HandBrake's geometry fix).
  /// Returns even (modulo=2) dimensions, never 0.
  static ({int width, int height}) calculate({
    required int srcWidth,
    required int srcHeight,
    int? maxWidth,
    int? maxHeight,
    int? targetWidth,
    int? targetHeight,
    double? scale,
    bool preserveAspectRatio = true,
    bool allowStretch = false,
    int modulus = 2,
  }) {
    assert(srcWidth > 0 && srcHeight > 0);
    final aspect = srcWidth / srcHeight;

    int w = srcWidth;
    int h = srcHeight;

    // Priority: explicit target > scale > max constraints (same as HandBrake's PictureForce* vs max PictureWidth/Height)
    if (targetWidth != null || targetHeight != null) {
      if (!preserveAspectRatio || allowStretch) {
        w = targetWidth ?? ((targetHeight! * aspect).round());
        h = targetHeight ?? ((targetWidth! / aspect).round());
      } else {
        // preserve aspect: fit inside targetW×targetH
        if (targetWidth != null && targetHeight != null) {
          final targetAspect = targetWidth / targetHeight;
          if (aspect > targetAspect) {
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
      // maxWidth/maxHeight as ceiling (HandBrake's PictureWidth/Height with KeepRatio)
      if (maxWidth != null && w > maxWidth) {
        w = maxWidth;
        h = (w / aspect).round();
      }
      if (maxHeight != null && h > maxHeight) {
        h = maxHeight;
        w = (h * aspect).round();
      }
    }

    w = _alignToModulus(w, modulus);
    h = _alignToModulus(h, modulus);
    w = w.clamp(modulus, 7680); // cap at 8K — avoids OOM on exotic inputs
    h = h.clamp(modulus, 7680);

    // never upscale unless explicitly asked via targetWidth/targetHeight/scale
    final isExplicitUpscale = targetWidth != null || targetHeight != null || scale != null;
    if (!isExplicitUpscale) {
      if (w > srcWidth || h > srcHeight) {
        w = _alignToModulus(srcWidth, modulus);
        h = _alignToModulus(srcHeight, modulus);
      }
    }

    return (width: w, height: h);
  }

  /// Correct width/height for rotation metadata (HandBrake's title->geometry + rotation fix).
  /// Rotation 90/270 swaps dimensions.
  static ({int width, int height}) applyRotation(int width, int height, int rotationDegrees) {
    final r = rotationDegrees % 360;
    if (r == 90 || r == 270) return (width: height, height: width);
    return (width: width, height: height);
  }

  static int _alignToModulus(int value, int modulus) {
    if (modulus <= 1) return value.clamp(1, 1 << 30);
    // Round to nearest multiple of modulus, at least modulus
    final aligned = ((value + modulus - 1) ~/ modulus) * modulus;
    // For modulus 2 we want even; subtract 1 if odd and value is > modulus
    if (aligned % modulus != 0) return aligned - (aligned % modulus);
    return aligned;
  }

  /// Estimate total frames for progress denominator (like job->frame_count from duration×fps).
  static int estimateTotalFrames({required int durationMs, required double fps}) {
    if (durationMs <= 0 || fps <= 0) return 0;
    return ((durationMs / 1000.0) * fps).round();
  }

  /// Progress math matching sync.c: progress = frame_count / est_frame_count, clamped.
  static double progress({required int encodedFrames, required int totalFrames}) {
    if (totalFrames <= 0) return 0;
    return (encodedFrames / totalFrames).clamp(0.0, 1.0);
  }

  /// Remaining wall-clock estimate — like HandBrake's estimatedRemaining derived from fps.
  static Duration? estimatedRemaining({required double progress, required Duration elapsed}) {
    if (progress <= 0 || progress >= 1) return null;
    final totalMs = elapsed.inMilliseconds / progress;
    final remainMs = (totalMs - elapsed.inMilliseconds).round();
    return Duration(milliseconds: math.max(0, remainMs));
  }
}
