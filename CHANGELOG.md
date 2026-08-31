# Changelog

## 1.0.11 — 2026-08-31 (preserve-resolution compression)

- **New API**: `VideoCompressionOptions.preserveResolution` — HandBrake-style
  "same as source": compresses at the exact source width/height (rotation-
  corrected), ignoring maxWidth/maxHeight/targetWidth/targetHeight/scale.
  Size reduction comes from bitrate/CQ alone, never from resizing.
- **Example app**: "Keep original resolution" toggle (default ON) — video
  uses `preserveResolution`; image compression drops the 2048 px cap so
  photos keep their native dimensions (safe: decode guard allows up to
  100 MP without caps).
- Tests: `preserveResolution` keeps 4K dimensions despite 720p caps, and
  portrait rotation-corrected sources stay intact. 100/100 Dart tests green.

## 1.0.10 — 2026-08-31 (Android CPU-path frame scaling — BufferOverflow fix)

- **🔴 crash fix**: the ByteBuffer encode path fed *full-source-resolution*
  frames into an encoder configured at the resized dimensions
  (`BufferOverflowException @ DirectByteBuffer` in `feedEncoderNv12` — the
  encoder's input buffers are sized for the target resolution). Surface input
  scales internally; the CPU path must scale explicitly. Added a tightly
  packed YUV420 nearest-neighbor scaler (HandBrake swscale stand-in) —
  decoded frames are now scaled to the encoder's exact size before feeding
  (NV12 or I420 output matching the negotiated layout). Now every tier of the
  encode pipeline works for any source resolution.
- Android JVM tests green, AAR builds (zero `.so`).

## 1.0.9 — 2026-08-31 (Android 3-tier encode fallback + self-describing errors)

- **Tiered encode pipeline** (HandBrake-style "always produce a result"):
  - Tier 0: CQ + Surface input (vendor/HW encoder preferred).
  - Tier 1: VBR + ByteBuffer YUV — no CQ/KEY_QUALITY, no input surface.
  - Tier 2: VBR + ByteBuffer + **forced software encoder/decoder**
    (`c2.android`/`OMX.google`) — always present, cannot be broken by vendor
    codec bugs; AV1 falls back to H.264 software when no AV1 software encoder
    exists.
  - Retries on ANY codec-side failure (CodecException, IllegalStateException,
    NPE, …); deterministic input failures (bad path, no track, truncated
    media), cancellation, stalls and validation errors never retry.
- **Self-describing errors**: `Unknown error` replaced with
  `ExceptionClass: message @ File.method:line` across every native error path
  — the next failure, if any, is immediately diagnosable.
- Android JVM tests green, AAR builds (zero `.so`), analyze clean.

## 1.0.8 — 2026-08-31 (Android YUV conversion crash + negotiated-format fix)

- **🔴 crash fix**: `Yuv.toNv12` threw `BufferUnderflowException` on Exynos
  devices (HEVC decode → ByteBuffer encode). Decoder `Image` planes violate
  naive assumptions: shared backing buffers with non-zero base position,
  restrictive limits, vendor-specific interleave order (NV21) and strides.
  The converter is now fully defensive — base-offset aware, bounds-clamped
  (never throws on odd geometry), detects NV12/NV21/planar layouts, and
  down-converts 10-bit (16-bit) chroma to 8-bit.
- **🔴 quality fix**: the encoder is queried for its *negotiated* input color
  format; when a vendor substitutes planar (e.g. `0x13`) for our flexible
  request, frames are fed as I420 instead of NV12 — previously the layout
  mismatch produced scrambled chroma.
- Verified against device logs: surface encode rejected by `OMX.Exynos.AVC.
  Encoder` (configure -38) → degraded ByteBuffer path now completes.
- Android JVM tests green.

## 1.0.7 — 2026-08-31 (Android encode runtime-crash retry)

- **🔴 Android**: a runtime `MediaCodec.CodecException` (e.g. `Error 0x80001001`
  buffer-manager error) failed the job outright. The transcoder now retries
  the full encode once with a maximally-compatible degraded profile — VBR (no
  CQ, no `KEY_QUALITY`) and ByteBuffer YUV input (no input surface). This
  avoids both known device breakers: surface+CQ pipelines and strict c2
  `KEY_QUALITY` handling. The CPU-fallback path also now inherits the retry
  profile instead of forcing CQ unconditionally.
- Android JVM tests green, analyze clean.

## 1.0.6 — 2026-08-31 (example: picker UX, findable outputs)

- **Image picking**: "Pick Image from Camera Roll" button (`image_picker`) —
  previously only videos could be picked, so photos captured on the device
  could not be compressed.
- **Unique output files**: example outputs are now `<name>_<preset>_handbreak_
  out_<timestamp>.mp4` in the app Documents dir — repeated compressions (e.g.
  a different preset) no longer collide with the previous output
  (`OutputCreationException`), and every result is preserved for comparison.
- **Findable results**: Documents-dir output persists across runs; iOS exposes
  it in the Files app (`UIFileSharingEnabled` + `LSSupportsOpeningDocuments
  InPlace`). Result card shows the full path, an **Open Output** button
  (`open_filex` — Android intent / iOS QuickLook), a **Copy Path** button, and
  a quality summary of the compressed file (resolution, codec, fps, bitrate,
  size) parsed from `outputMediaInfo`.
- 96/96 Dart tests green (incl. example widget smoke test), analyze clean.

## 1.0.5 — 2026-08-31 (channel map cast fix)

- **🔴 crash fix**: `CompressionResult.fromMap` cast
  `m['outputMediaInfo'] as Map<String, dynamic>?` threw
  `Map<Object?, Object?> is not a subtype of Map<String, dynamic>` — the
  method channel decodes nested maps as `Map<Object?, Object?>`, and a strict
  cast on the runtime type fails. Now converted with the same
  `Map<String, dynamic>.from(...)` pattern used elsewhere; no other strict
  `as Map<String, ...>` casts remain in the library.
- Regression test: `CompressionResult.fromMap accepts channel-decoded nested
  maps` reproduces the exact native payload shape.
- 95/95 Dart unit tests green, analyze clean.

## 1.0.4 — 2026-08-31 (real-world input hardening)

- **🔴 rotation from container metadata**: `KEY_ROTATION` is frequently absent
  from Android `MediaExtractor` output (esp. HEVC / MOV); the probe now falls
  back to `MediaMetadataRetriever`'s rotation (tkhd matrix) so portrait
  detection & dimension swap work on camera-roll files.
- **🔴 truncated-input guard**: moov-fronted files parse cleanly even when the
  media data is cut short — the probe now compares the last sample PTS
  against the declared duration and throws `InvalidInput` instead of silently
  reporting a full-length file.
- **🔴 CQ encode fix**: strict c2 codecs reject `BITRATE_MODE_CQ` configs
  without `KEY_QUALITY` (EINVAL); the transcoder now sets `KEY_QUALITY`
  derived from the resolved CRF, and retries with plain VBR if a device
  refuses CQ outright.
- **🔴 iOS progress stream**: stream handler no longer captures the sink in a
  throwing escape position; `FlutterEventSink` is explicitly `@escaping`,
  eliminating a crash on progress events.
- **🔴 progress-stream lifecycle**: Dart side ignores events/errors after the
  controller is closed and `_markTerminal` now *keeps* jobs in the terminated
  set (previously removed — stale stream registrations could leak native
  channel subscriptions).
- **iOS podspec renamed** to `flutter_handbreak.podspec` (was `handbreak`) —
  must match the package name for CocoaPods integration.
- **Example upgraded to a standalone app**: Android/iOS host projects,
  camera-roll picking (`image_picker`), self-contained integration lanes with
  bundled fixtures, and a real widget smoke test (template counter test was
  broken).
- `tool/verify.sh`: `readlink -f` is GNU-only — FLUTTER_ROOT now resolves via
  `pwd -P`, so the Android lane works on macOS.
- Verification: analyze clean, 94 Dart unit tests, Swift typecheck, Android
  JVM tests green, AAR rebuilt (still zero `.so`).

## 1.0.3 — 2026-08-23 (deep multimedia correctness)

- **🔴 muxer ordering**: audio-transcode track registration counted in
  `pendingTracks` — `MediaMuxer.start()` now waits for BOTH video and audio
  track registration (previously a race where the video encoder's
  format-changed could `start()` before the audio track existed →
  `addTrack` after `start()` threw IllegalStateException on transcode jobs).
- **🔴 bounded waits**: iOS export wait is now watchdog-bounded — 30 s without
  session progress cancels the export and fails with `TIMEOUT` instead of
  hanging forever (`done.wait()` was unbounded).
- **🔴 explicit queue capacity**: `JobManager` now uses a structural
  `ThreadPoolExecutor(1, ArrayBlockingQueue(8))` — no semaphore, no soft
  counters; overflow is rejected synchronously (`QUEUE_FULL`).
- **🔴 cancellation semantics**: `CANCELLING` (requested) is distinct from
  `CANCELLED` (terminal). `cancelJob` requests; the worker drains, then the
  plugin marks the terminal state. iOS mirrors this with a `cancelRequested`
  flag + `.cancelling` state.
- **Integration/stress lane**: `integration_test/` device harness (probe,
  rotation, A/V sync, keep-original, cancellation storms, queue bounds,
  decompression-bomb) with fixture manifest — ready to run on hardware,
  documented as UNVERIFIED until run.
- **Claims tightened**: README image/filter claims match implementation;
  install example pinned to `^1.0.2`; archive size updated to measured
  ~102 KB / zero `.so`; explicit "Verification status" section added.
- `tool/verify.sh` extended with the iOS Swift typecheck lane.
- JVM test suite: 16/16 passing (bounded-queue determinism fixed).

## 1.0.2 — 2026-08-23 (first real Kotlin compile — critical)

- **The Android plugin now actually compiles.** First standalone Gradle build
  (unit tests + release AAR) surfaced genuine compile errors that a consumer's
  app build would have hit:
  - `Options.container` property missing (unresolved reference)
  - `Plan.containerFallbackNote/hwFallbackNote` referenced but never parsed
  - `MUXER_OUTPUT_THREE_GPP` absent from compileSdk 34 android.jar → version-guarded literal
  - nullable result values vs `Map<String, Any>` → relaxed to `Map<String, Any?>`
  - missing `return` in `transcode` terminal statement
  - `kotlin.math.abs` import missing
  - `mainHandler.post` Boolean/Unit mismatch in waitForResult
- **16 JVM unit tests now execute** (Gradle `testDebugUnitTest`): Downmix,
  ResolutionHelper, JobManager (non-blocking submit, idempotent cancel,
  bounded queue, queued-job cancellation, state machine). All pass.
- `assembleRelease` verified: 92 KB AAR, classes.jar only, **zero native .so
  binaries** (lightweight claim now measured, not assumed).
- JVM test expectations corrected (stereo→mono output size, 5ch→stereo frame
  math, ExecutionException-wrapped task cancellation).

## 1.0.1 — 2026-08-23 (final hardening pass)

- **P0**: unbounded codec feed loops eliminated — NV12/PCM/EOS delivery is now
  bounded (15 s stall deadline), cancellation-aware, and fails with a dedicated
  stall error instead of hanging forever on a broken encoder.
- **P1**: per-lane stall watchdog (audio activity can no longer mask a dead video
  lane); Android `disposeJob` now cancels running work (parity with iOS);
  iOS orientation applied exactly once (track transform zeroed when a
  videoComposition owns the transform — fixes double-rotation risk on
  resize/fps-cap); `waitForResult` moved to its own executor so probing a new
  file never blocks behind a running job.
- **P2**: bounded admission queue (max 8 queued, `QUEUE_FULL` error);
  100 MP decompression-bomb guard for images (fail safely, instruct caller);
  overwrite policy enforced on the extension-renamed image output;
  codec wait timeout 10 s → 1 s (fast cancellation); fractional FPS rounded.
- **P3**: `CompressionTimeoutException` added to the typed error hierarchy
  (native `TIMEOUT`); docs updated with device-UNVERIFIED items.
- Tests: +2 JVM queue tests (bounded admission, queued-job cancellation),
  +1 Dart error-parity case. 94 Dart + 17 JVM cases.

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

