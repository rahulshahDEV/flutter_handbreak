/// Snapshot of device encode/decode capabilities. Queried via native MediaCodecList / VideoToolbox.
class HardwareCapabilities {
  const HardwareCapabilities({
    required this.supportsHardwareH264Encode,
    required this.supportsHardwareH265Encode,
    required this.supportsHardwareAv1Encode,
    required this.supportsHardwareVp9Encode,
    required this.supportsHardwareDecode,
    required this.platform,
    this.details = const {},
  });

  final bool supportsHardwareH264Encode;
  final bool supportsHardwareH265Encode;
  final bool supportsHardwareAv1Encode;
  final bool supportsHardwareVp9Encode;
  final bool supportsHardwareDecode;
  final String platform;
  final Map<String, dynamic> details;

  bool get supportsHardwareH264 => supportsHardwareH264Encode;
  bool get supportsHardwareH265 => supportsHardwareH265Encode;
  bool get supportsHardwareAv1 => supportsHardwareAv1Encode;

  bool supportsEncodeFor(String codecId) {
    switch (codecId) {
      case 'h264':
        return supportsHardwareH264Encode;
      case 'h265':
        return supportsHardwareH265Encode;
      case 'av1':
        return supportsHardwareAv1Encode;
      case 'vp9':
        return supportsHardwareVp9Encode;
      default:
        return false;
    }
  }

  factory HardwareCapabilities.fromMap(Map<String, dynamic> map) {
    return HardwareCapabilities(
      supportsHardwareH264Encode:
          map['supportsHardwareH264Encode'] as bool? ?? false,
      supportsHardwareH265Encode:
          map['supportsHardwareH265Encode'] as bool? ?? false,
      supportsHardwareAv1Encode:
          map['supportsHardwareAv1Encode'] as bool? ?? false,
      supportsHardwareVp9Encode:
          map['supportsHardwareVp9Encode'] as bool? ?? false,
      supportsHardwareDecode: map['supportsHardwareDecode'] as bool? ?? false,
      platform: map['platform'] as String? ?? 'unknown',
      details: Map<String, dynamic>.from(map['details'] as Map? ?? {}),
    );
  }

  Map<String, dynamic> toMap() => {
        'supportsHardwareH264Encode': supportsHardwareH264Encode,
        'supportsHardwareH265Encode': supportsHardwareH265Encode,
        'supportsHardwareAv1Encode': supportsHardwareAv1Encode,
        'supportsHardwareVp9Encode': supportsHardwareVp9Encode,
        'supportsHardwareDecode': supportsHardwareDecode,
        'platform': platform,
        'details': details,
      };

  @override
  String toString() =>
      'HardwareCapabilities(H264:$supportsHardwareH264Encode H265:$supportsHardwareH265Encode AV1:$supportsHardwareAv1Encode VP9:$supportsHardwareVp9Encode decode:$supportsHardwareDecode platform:$platform)';
}
