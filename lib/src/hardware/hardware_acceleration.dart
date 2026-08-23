/// Hardware encoder selection policy — mirrors HandBrake's hwaccel fallback logic.
enum HardwareAcceleration {
  /// Try hardware; silently fall back to software if unavailable or unsupported for config.
  auto,
  /// Prefer hardware; fall back to software if unavailable.
  hardwarePreferred,
  /// Only hardware — throws [HardwareEncoderUnavailableException] if not possible.
  hardwareOnly,
  /// Force software (deterministic quality, no HW variance).
  softwareOnly,
}
