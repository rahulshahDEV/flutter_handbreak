enum ImageFormat {
  auto('auto'),
  jpeg('jpeg'),
  png('png'),
  webp('webp'),
  heic('heic'),
  heif('heif'),
  avif('avif');

  const ImageFormat(this.id);
  final String id;

  static ImageFormat fromId(String id) =>
      values.firstWhere((e) => e.id == id, orElse: () => ImageFormat.auto);

  bool get supportsAlpha =>
      this == ImageFormat.png ||
      this == ImageFormat.webp ||
      this == ImageFormat.heic ||
      this == ImageFormat.heif ||
      this == ImageFormat.avif ||
      this == ImageFormat.auto;
  bool get isLossy =>
      this == ImageFormat.jpeg ||
      this == ImageFormat.webp ||
      this == ImageFormat.heic ||
      this == ImageFormat.heif ||
      this == ImageFormat.avif;
}
