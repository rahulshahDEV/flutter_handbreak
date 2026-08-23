/// Discrete constant-quality levels. Mapped codec-specifically in [QualityMapper].
/// DO NOT treat these as universal numbers; each codec maps them to its own CRF/QP range.
enum VideoQuality {
  veryHigh,
  high,
  medium,
  low,
  veryLow,
}

/// Preferred rate-control mode. Constant-quality is default (HandBrake-aligned).
sealed class RateControl {
  const RateControl();

  const factory RateControl.constantQuality(VideoQuality quality) =
      ConstantQualityRateControl;
  const factory RateControl.averageBitrate(int bitrateKbps, {bool twoPass}) =
      AverageBitrateRateControl;
  const factory RateControl.constantQualityValue(double value) =
      ConstantQualityValueRateControl;

  Map<String, dynamic> toMap();
}

/// Constant-quality via discrete level → codec-aware CRF resolution.
class ConstantQualityRateControl extends RateControl {
  const ConstantQualityRateControl(this.quality);
  final VideoQuality quality;

  @override
  Map<String, dynamic> toMap() => {
        'mode': 'cq',
        'quality': quality.name,
      };
}

/// Constant-quality via explicit native CRF/QP numeric.
/// Advanced; codec-specific valid ranges apply — see [QualityMapper.validRangeFor].
class ConstantQualityValueRateControl extends RateControl {
  const ConstantQualityValueRateControl(this.value);
  final double value;

  @override
  Map<String, dynamic> toMap() => {
        'mode': 'cq_value',
        'value': value,
      };
}

/// Average-bitrate mode. Two-pass only where it provides real value — disabled by default on mobile.
class AverageBitrateRateControl extends RateControl {
  const AverageBitrateRateControl(this.bitrateKbps, {this.twoPass = false});
  final int bitrateKbps;
  final bool twoPass;

  @override
  Map<String, dynamic> toMap() => {
        'mode': 'abr',
        'bitrateKbps': bitrateKbps,
        'twoPass': twoPass,
      };
}
