/// Composable filter pipeline inspired by HandBrake's hb_filter_object_t chain.
/// Filters are data objects; native resolves ordering and executes them.
///
/// HandBrake's ordering (work.c:sanitize_filter_list_pre/post):
///   crop → scale → pad → rotate → deinterlace/decomb/detelecine → denoise → sharpen → colorspace → grayscale
/// Native preserves a compatible canonical order regardless of input list order, matching HandBrake's sanitization.
sealed class VideoFilter {
  const VideoFilter();
  Map<String, dynamic> toMap();
}

class CropFilter extends VideoFilter {
  const CropFilter({this.top = 0, this.bottom = 0, this.left = 0, this.right = 0});
  final int top, bottom, left, right;
  @override
  Map<String, dynamic> toMap() => {'type': 'crop', 'top': top, 'bottom': bottom, 'left': left, 'right': right};
}

class ScaleFilter extends VideoFilter {
  const ScaleFilter({this.width, this.height, this.algorithm = ScaleAlgorithm.lanczos});
  final int? width;
  final int? height;
  final ScaleAlgorithm algorithm;
  @override
  Map<String, dynamic> toMap() => {'type': 'scale', 'width': width, 'height': height, 'algorithm': algorithm.name};
}

enum ScaleAlgorithm { fastBilinear, bilinear, bicubic, lanczos }

class PadFilter extends VideoFilter {
  const PadFilter({required this.width, required this.height, this.color = 0x000000});
  final int width;
  final int height;
  final int color;
  @override
  Map<String, dynamic> toMap() => {'type': 'pad', 'width': width, 'height': height, 'color': color};
}

class RotateFilter extends VideoFilter {
  const RotateFilter(this.degrees, {this.flipHorizontal = false, this.flipVertical = false});
  final int degrees; // 0/90/180/270
  final bool flipHorizontal;
  final bool flipVertical;
  @override
  Map<String, dynamic> toMap() => {'type': 'rotate', 'degrees': degrees, 'flipH': flipHorizontal, 'flipV': flipVertical};
}

class DeinterlaceFilter extends VideoFilter {
  const DeinterlaceFilter({this.mode = DeinterlaceMode.decomb});
  final DeinterlaceMode mode;
  @override
  Map<String, dynamic> toMap() => {'type': 'deinterlace', 'mode': mode.name};
}

enum DeinterlaceMode { off, decomb, bob, yadif }

class DenoiseFilter extends VideoFilter {
  const DenoiseFilter({this.strength = DenoiseStrength.light, this.tune = 'none'});
  final DenoiseStrength strength;
  final String tune; // none | film | animation | grain
  @override
  Map<String, dynamic> toMap() => {'type': 'denoise', 'strength': strength.name, 'tune': tune};
}

enum DenoiseStrength { off, light, medium, strong, custom }

class SharpenFilter extends VideoFilter {
  const SharpenFilter({this.strength = SharpenStrength.medium});
  final SharpenStrength strength;
  @override
  Map<String, dynamic> toMap() => {'type': 'sharpen', 'strength': strength.name};
}

enum SharpenStrength { off, light, medium, strong }

class GrayscaleFilter extends VideoFilter {
  const GrayscaleFilter();
  @override
  Map<String, dynamic> toMap() => {'type': 'grayscale'};
}
