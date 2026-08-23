# Changelog

## 0.2.0 — 2026-08-22 (production hardening)

Full audit: [PRODUCTION_REVIEW.md](PRODUCTION_REVIEW.md).

### Architecture
- **EncodePlanResolver**: all encode policy (dimensions, fps gate, container fallback,
  rate control, hardware decision, audio plan, filter ordering) resolved once in
  pure Dart with 30+ unit tests; natives execute the plan instead of re-deriving heuristics.

### Fixed
- Android: audio was dropped entirely → now passthrough or AAC-LC transcode, PTS-interleaved.
- Android: framerate gate corrupted bitstream (empty-buffer queue) → decoder-output PTS gate,
  drop-only, deterministic.
- Android: byte-buffer fallback was a silent hang stub → real YUV_420_888→NV12 converter
  (semi-planar + planar strides) feeding encoder.
- iOS: Swift would not compile (inout-capture handler, missing UIKit import) → clean rewrite
  across Support/HardwareProbe/MediaProbe/JobManager/pipelines; typechecks on iOS SDK.
- iOS: EXIF orientation computed but ignored → transform-aware thumbnail decode (all 8 cases).
- iOS: fake `usedHardwareAcceleration` → real VTCompressionSession hardware-required probes;
  unenforceable softwareOnly recorded honestly in result notes.
- MKV/WebM requests that mobile muxers cannot write now fall back to MP4 with an explicit
  note in `qualityWarning` instead of failing at mux time.
- Dart: `ImageCompressor.compress` typed result; platform registration via
  `ensureInitialized()` (no private-class sniffing); progress streams self-terminate (no leak).
- Hardware-decode capability no longer counts non-video decoders.

### Added
- Container/audio/hardware fallback matrix with surfaced notes (`ResolvedPlan`).
- Stall watchdog on Android pipeline (fails loudly after 30 s without progress).
- Tests: resolver fallbacks, filter canonical order, validation helpers, error-code parity.

## 0.1.0 — 2026-08-22

- Initial release, Phase 1.
- Dart API: VideoCompressor / ImageCompressor, HandbreakProbe, presets, quality mapper, hardware detection abstraction.
- Android: MediaExtractor probe, MediaCodec encode (H.264), MediaMuxer, Bitmap image path, JobManager with cancellation & temp cleanup, progress via EventChannel.
- iOS: AVFoundation/VideoToolbox pipeline, ImageIO/CoreGraphics image path, JobManager.
- Docs: ARCHITECTURE.md (HandBrake analysis), THIRD_PARTY_LICENSES, example app, benchmark harness.
