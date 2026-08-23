# Changelog

## 1.0.0 — 2026-08-23

- **First stable release** (published on pub.dev as flutter_handbreak).
- Documentation restructure: clean README + detailed docs under `doc/`
  (API reference, quality model, platform matrix, architecture, migration roadmap).
- Full validation: analyze clean, 94 unit tests green, Swift typecheck clean,
  pub.dev dry-run 0 warnings.

## 0.3.1 — 2026-08-23 (audit v3: crash & concurrency hardening)

- Android: semaphore no longer acquired on the main thread (ANR fix) — queued jobs wait on the worker.
- Android: probe + capabilities moved off the platform thread; engine detach now cancels running jobs.
- Android: audio transcode never drops decoded PCM (retry-until-fed, cancellation-aware).
- Android: negative/non-monotonic PTS normalized before mux (MediaMuxer rejection fix).
- Android: half-created decoder released on configure failure (no leak).
- Android: job-scoped temp files (`output.hbtmp.<jobId>`) — no cross-job collision.
- Android/iOS: requested HEIC/AVIF that a device cannot encode now falls back to JPEG **and reports it** (`qualityWarning`) instead of silently lying about the codec.
- iOS: image decode no longer loads the entire file into memory (URL-based ImageIO source).
- iOS: job task access synchronized (TSAN race fixed); duration validation parity with Android.
- iOS: capabilities probe moved off the main thread.
- Formal job state machine on both natives; state surfaced in progress payloads.
- Dart: probe + capabilities resolved in parallel.

## 0.3.0 — 2026-08-23

- Rename package to `flutter_handbreak` (keep `handbreak.dart` alias for compatibility)
- Add lightweight `FlutterHandbreak` facade: `compressVideo(path, quality: 80, preset: ...)` one-liner
- HandBrake-inspired credit banner + funding metadata for pub.dev
- Exclude internal docs (PRODUCTION_REVIEW) from published archive — clean open-source
- Fix facade unused import, example dependency rename


## 0.2.0 — 2026-08-22 (production hardening)

Full audit of v0.2 hardening (internal, not shipped).

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

