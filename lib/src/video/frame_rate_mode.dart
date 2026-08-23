/// Frame-rate handling. Mirrors HandBrake's CFR/VFR choice.
enum FrameRateMode {
  /// Keep source rate (HandBrake default unless capped). Constant if maxFrameRate set.
  sameAsSource,
  /// Allow encoder to emit variable frame rate (drop/duplicate only when needed).
  variable,
  /// Force constant frame rate; timestamp normalization via sync stage.
  constant,
}
