import 'image_format.dart';

class ImageCompressionOptions {
  const ImageCompressionOptions({
    this.quality = 82,
    this.maxWidth,
    this.maxHeight,
    this.format = ImageFormat.auto,
    this.preserveExif = false,
    this.preserveAlpha = true,
    this.progressive = false,
    this.keepOriginalIfSmaller = true,
    this.overwriteExisting = false,
  });

  /// 0..100 — perceptual quality (higher = larger & better). 82 is a balanced default.
  final int quality;
  final int? maxWidth;
  final int? maxHeight;
  final ImageFormat format;
  final bool preserveExif;
  final bool preserveAlpha;
  final bool progressive; // progressive JPEG when format=jpeg
  final bool keepOriginalIfSmaller;
  final bool overwriteExisting;

  void validate() {
    if (quality < 0 || quality > 100) {
      throw ArgumentError('quality must be 0..100');
    }
    if (maxWidth != null && maxWidth! <= 0) {
      throw ArgumentError('maxWidth must be > 0');
    }
    if (maxHeight != null && maxHeight! <= 0) {
      throw ArgumentError('maxHeight must be > 0');
    }
  }

  Map<String, dynamic> toMap() => {
        'quality': quality,
        if (maxWidth != null) 'maxWidth': maxWidth,
        if (maxHeight != null) 'maxHeight': maxHeight,
        'format': format.id,
        'preserveExif': preserveExif,
        'preserveAlpha': preserveAlpha,
        'progressive': progressive,
        'keepOriginalIfSmaller': keepOriginalIfSmaller,
        'overwriteExisting': overwriteExisting,
      };
}
