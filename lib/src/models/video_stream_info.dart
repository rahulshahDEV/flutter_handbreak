class VideoStreamInfo {
  const VideoStreamInfo({
    required this.index,
    required this.codec,
    required this.codecString,
    required this.width,
    required this.height,
    this.rawWidth = 0,
    this.rawHeight = 0,
    required this.rotation,
    required this.frameRate,
    required this.averageFrameRate,
    required this.isVariableFrameRate,
    required this.durationMs,
    required this.bitRate,
    required this.pixelFormat,
    required this.colorPrimaries,
    required this.colorTransfer,
    required this.colorMatrix,
    required this.colorRange,
    required this.bitDepth,
    required this.isHdr,
    required this.hdrType,
    required this.displayAspectRatio,
    required this.sampleAspectRatio,
    this.profile,
    this.level,
    this.language,
  });

  final int index;
  final String codec;
  final String codecString;

  /// Rotation-corrected display dimensions.
  final int width;
  final int height;

  /// Storage (decoded) dimensions — what the decoder actually outputs.
  /// Encoders must be sized from these; [width]/[height] are display logic.
  final int rawWidth;
  final int rawHeight;

  final int
      rotation; // 0/90/180/270 — rotation-corrected dimensions already applied to width/height
  final double frameRate;
  final double averageFrameRate;
  final bool isVariableFrameRate;
  final int durationMs;
  final int bitRate;
  final String pixelFormat;
  final String colorPrimaries;
  final String colorTransfer;
  final String colorMatrix;
  final String colorRange;
  final int bitDepth;
  final bool isHdr;
  final String? hdrType; // hdr10 | hlg | dovi | hdr10plus
  final double displayAspectRatio;
  final double sampleAspectRatio;
  final String? profile;
  final String? level;
  final String? language;

  /// Storage (decoded) dimensions — falls back to display dims for legacy payloads.
  int get storageWidth => rawWidth > 0 ? rawWidth : width;
  int get storageHeight => rawHeight > 0 ? rawHeight : height;

  /// Portrait after rotation correction?
  bool get isPortrait => height > width;

  factory VideoStreamInfo.fromMap(Map<String, dynamic> m) => VideoStreamInfo(
        index: m['index'] as int? ?? 0,
        codec: m['codec'] as String? ?? 'unknown',
        codecString:
            m['codecString'] as String? ?? m['codec'] as String? ?? 'unknown',
        width: m['width'] as int? ?? 0,
        height: m['height'] as int? ?? 0,
        rawWidth: m['rawWidth'] as int? ?? 0,
        rawHeight: m['rawHeight'] as int? ?? 0,
        rotation: m['rotation'] as int? ?? 0,
        frameRate: (m['frameRate'] as num?)?.toDouble() ?? 0,
        averageFrameRate: (m['averageFrameRate'] as num?)?.toDouble() ??
            (m['frameRate'] as num?)?.toDouble() ??
            0,
        isVariableFrameRate: m['isVariableFrameRate'] as bool? ?? false,
        durationMs: m['durationMs'] as int? ?? 0,
        bitRate: m['bitRate'] as int? ?? 0,
        pixelFormat: m['pixelFormat'] as String? ?? 'unknown',
        colorPrimaries: m['colorPrimaries'] as String? ?? 'unknown',
        colorTransfer: m['colorTransfer'] as String? ?? 'unknown',
        colorMatrix: m['colorMatrix'] as String? ?? 'unknown',
        colorRange: m['colorRange'] as String? ?? 'unknown',
        bitDepth: m['bitDepth'] as int? ?? 8,
        isHdr: m['isHdr'] as bool? ?? false,
        hdrType: m['hdrType'] as String?,
        displayAspectRatio: (m['displayAspectRatio'] as num?)?.toDouble() ??
            (m['width'] != null &&
                    m['height'] != null &&
                    (m['height'] as int) != 0
                ? (m['width'] as int) / (m['height'] as int)
                : 0),
        sampleAspectRatio: (m['sampleAspectRatio'] as num?)?.toDouble() ?? 1.0,
        profile: m['profile'] as String?,
        level: m['level'] as String?,
        language: m['language'] as String?,
      );

  Map<String, dynamic> toMap() => {
        'index': index,
        'codec': codec,
        'codecString': codecString,
        'width': width,
        'height': height,
        'rawWidth': rawWidth,
        'rawHeight': rawHeight,
        'rotation': rotation,
        'frameRate': frameRate,
        'averageFrameRate': averageFrameRate,
        'isVariableFrameRate': isVariableFrameRate,
        'durationMs': durationMs,
        'bitRate': bitRate,
        'pixelFormat': pixelFormat,
        'colorPrimaries': colorPrimaries,
        'colorTransfer': colorTransfer,
        'colorMatrix': colorMatrix,
        'colorRange': colorRange,
        'bitDepth': bitDepth,
        'isHdr': isHdr,
        'hdrType': hdrType,
        'displayAspectRatio': displayAspectRatio,
        'sampleAspectRatio': sampleAspectRatio,
        'profile': profile,
        'level': level,
        'language': language,
      };
}
