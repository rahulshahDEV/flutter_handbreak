# flutter_handbreak

**Lightweight Flutter video & image compression — inspired by HandBrake, built for mobile.**

> **Inspired by HandBrake** — Pipeline, quality model and presets are inspired by HandBrake (https://handbrake.fr, GPL-2.0). No HandBrake code is bundled — concepts are re-implemented in Dart/Kotlin/Swift under MIT. See `ARCHITECTURE.md`.

`handbreak` is a Flutter plugin that brings HandBrake's *pipeline philosophy* to Android & iOS without shipping GPL binaries or blocking the UI. It uses `MediaCodec`/`MediaMuxer` on Android and `VideoToolbox`/`AVFoundation` on iOS for hardware-accelerated encoding, with a clean Dart API for quality, presets, progress & cancellation.

> HandBrake itself is not embedded. Its architecture (libhb's probe → demux → decode → sync → filter chain → encode → mux lifecycle) was studied to design this package's pipeline, quality model, and resource management. See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full analysis.

---

## Features

- **Video**: H.264 (default), H.265/HEVC, AV1, VP9 · MP4/MOV/MKV · constant-quality (default) & ABR (+ optional 2-pass)
- **Image**: JPEG, PNG, WebP, HEIC/HEIF, AVIF (platform-gated) · EXIF-aware · alpha-preserving
- **Probe**: container, duration, geometry (rotation-corrected), fps, VFR flag, color/HDR, bitrate, audio streams
- **Filters**: crop / scale / pad / rotate / deinterlace / denoise / sharpen / grayscale — composable, canonical order
- **Hardware**: runtime detection (`MediaCodecList` / `VideoToolbox`), `HardwareAcceleration.auto` → HW → SW fallback with `usedHardwareAcceleration` reporting
- **Quality model**: discrete `VideoQuality` mapped codec-aware to native CRF/QP (H.264 ≠ H.265 ≠ AV1) + `AdvancedEncoderOptions(crf:...)` escape hatch
- **Presets**: `fast` · `balanced` · `highQuality` · `smallFile` · `socialMedia` · `messaging` · `web` · `archive`
- **Progress**: real PTS/frame-based `CompressionProgress` via `EventChannel`, never fake timers
- **Cancellation**: idempotent `job.cancel()` → stops codec, releases threads, deletes partial `.tmp`
- **Safety**: never overwrites input unless `overwriteExisting`, unique `.tmp` + atomic rename, bounded executor (default 1 concurrent job), streaming I/O (no giant byte arrays)

---

## Install

```yaml
dependencies:
  flutter_handbreak: ^0.1.0
```

Android `minSdk 21`, iOS 13+. No extra native setup required — platform codecs are used. Optional FFmpeg LGPL build is *not* bundled by default (see [Licensing](#licensing)).

---

## Quick start

### Video — simple

```dart
import 'package:flutter_handbreak/flutter_handbreak.dart';

final result = await VideoCompressor.compress(
  '/path/input.mp4',
  options: const VideoCompressionOptions(
    quality: VideoQuality.medium,        // discrete → codec-aware CRF
    maxWidth: 1920,
    maxHeight: 1080,
    maxFrameRate: 30,
    codec: VideoCodec.h264,              // VideoCodec.h265 / .av1 / .vp9
    container: VideoContainer.mp4,
    hardwareAcceleration: HardwareAcceleration.auto,
  ),
);
print('Saved ${result.compressionPercentage.toStringAsFixed(1)}%  hw=${result.usedHardwareAcceleration}');
print('Output: ${result.outputPath}');
```

### Video — with progress, preset & cancellation

```dart
final job = await VideoCompressor.start(
  inputPath,
  options: VideoPresetId.socialMedia.toOptions(), // H.264 MP4 1080×1920 @30, AAC stereo
  // or explicit:
  // options: const VideoCompressionOptions(
  //   presetName: 'socialMedia',
  //   rateControl: RateControl.constantQuality(VideoQuality.medium),
  //   frameRateMode: FrameRateMode.sameAsSource,
  //   audio: AudioOptions(bitrateKbps: 128),
  //   hardwareAcceleration: HardwareAcceleration.hardwarePreferred,
  //   filters: [CropFilter(top: 10, bottom: 10)],
  // ),
);

job.progress.listen((p) {
  print('${(p.progress*100).toStringAsFixed(1)}%  ${p.encodedFrames}/${p.totalFrames}  ${p.currentFps.toStringAsFixed(1)}fps  ETA ${p.estimatedRemaining}');
});

final result = await job.result; // CompressionResult
// or cancel:
// await job.cancel(); // throws CancelledCompressionException on result
```

### Preset one-liner

```dart
final result = await VideoCompressor.compressWithPreset(
  inputPath,
  VideoPresetId.balanced,
  override: (base) => base.copyWith(maxWidth: 1280),
);
```

### Image

```dart
final result = await ImageCompressor.compress(
  '/path/photo.jpg',
  options: const ImageCompressionOptions(
    quality: 82,                 // 0..100
    maxWidth: 2048,
    maxHeight: 2048,
    format: ImageFormat.auto,    // auto → JPEG/PNG/WebP/HEIC depending on alpha & platform
    preserveExif: false,
    keepOriginalIfSmaller: true, // never grows the file
  ),
) as CompressionResult;
```

### Probe

```dart
final info = await HandbreakProbe.probe('/path/clip.mov');
print(info.primaryVideo); // VideoStreamInfo {1920x1080 h264 30fps rot=90 hdr=false}
print(info.primaryAudio); // AudioStreamInfo {aac 44100Hz 2ch}
print(info.isPortrait);   // true for rotation-corrected portrait
print(info.isHdr);
```

---

## API

Top-level exports (`lib/handbreak.dart`):

```dart
VideoCompressor          // compress() / start() / compressWithPreset()
ImageCompressor          // compress() / start()
HandbreakProbe           // probe()
HardwareCapabilities     // supportsHardwareH264/H265/Av1, supportsHardwareDecode
VideoCompressionOptions  // codec/container/rateControl/maxWidth/maxHeight/frameRateMode/audio/hardwareAcceleration/filters/advanced
ImageCompressionOptions  // quality/maxWidth/maxHeight/format/preserveExif
RateControl              // constantQuality(VideoQuality) | averageBitrate(kbps, twoPass:) | constantQualityValue(double)
VideoQuality             // veryHigh/high/medium/low/veryLow — codec-aware mapped
VideoCodec               // h264/h265/av1/vp9    VideoContainer mp4/mov/mkv
VideoPresetId            // fast/balanced/highQuality/smallFile/socialMedia/messaging/web/archive
CompressionJob           // id, progress Stream<CompressionProgress>, result Future<CompressionResult>, cancel()
CompressionResult        // originalSize/outputSize/savedBytes/ratio/percentage/durationMs/usedHardwareAcceleration/qualityWarning/wasKeptOriginal/outputMediaInfo
CompressionProgress      // progress 0..1, processedDuration/totalDuration, encodedFrames/totalFrames, currentFps, estimatedRemaining, stage
MediaInfo / VideoStreamInfo / AudioStreamInfo
HandbreakException subtypes: InvalidInputException, UnsupportedFormatException, CodecUnavailableException, HardwareEncoderUnavailableException, OutputCreationException, EncodingException, CancelledCompressionException, InsufficientStorageException, OutOfMemoryException
```

### Rate control

- **Default is constant-quality** (HandBrake-aligned): `RateControl.constantQuality(VideoQuality.medium)` → CRF per codec (H.264 23, H.265 25, AV1 38 at medium). Size is an outcome, not a guarantee.
- `RateControl.averageBitrate(2500)` for ABR; `twoPass: true` only where it helps (disabled by default on mobile).
- `AdvancedEncoderOptions(crf: 22, preset: 'slow', tune: 'film')` for codec-specific tuning.

### Resolution & frame rate

- `maxWidth`/`maxHeight` cap while preserving aspect (HandBrake's `PictureWidth/Height` + `KeepRatio`). `targetWidth`/`targetHeight` for explicit size, `scale: 0.5` for factor. Never upscales unless explicit.
- Portrait with `rotation` metadata stays portrait (geometry is rotation-corrected).
- `frameRateMode: FrameRateMode.sameAsSource` (default), `variable`, `constant` + `maxFrameRate: 30` for deterministic capping. VFR sources preserved unless `maxFrameRate` forces drop.

### Filter pipeline (composable)

```dart
filters: [
  const CropFilter(top: 0, bottom: 0, left: 0, right: 0),
  const ScaleFilter(width: 1280, height: 720),
  const DenoiseFilter(strength: DenoiseStrength.light),
]
```

Native canonicalizes order (crop → scale → pad → rotate → deinterlace → denoise → sharpen → colorspace → grayscale) like `sanitize_filter_list_pre/post`.

---

## Hardware acceleration — real, not fake

`HardwareCapabilities` is queried at runtime via `MediaCodecList` (Android) / `VTIsHardwareDecodeSupported` (iOS). Selection policy mirrors HandBrake's `hb_hwaccel_can_use_full_hw_pipeline`:

```
hwAccel == auto/hardwarePreferred → try HW, verify encoder creation, fall back to SW on failure
hwAccel == hardwareOnly           → throw HardwareEncoderUnavailableException if HW unavailable
hwAccel == softwareOnly           → deterministic SW path
```

`result.usedHardwareAcceleration` reports what was actually used. Surface zero-copy (decode Surface → encode input Surface) is used when the filter list allows it; otherwise frames are downloaded for CPU filters then re-uploaded.

---

## Project layout

```
lib/src/
  api/           VideoCompressor / ImageCompressor
  models/        MediaInfo, Video/AudioStreamInfo, CompressionResult/Progress/Job
  video/         VideoCodec/Container, RateControl, FrameRateMode, filters
  image/         ImageFormat, ImageCompressionOptions
  presets/       VideoPresetId → VideoCompressionOptions mapping
  hardware/      HardwareCapabilities, HardwareAcceleration
  platform/      HandbreakPlatform + MethodChannelHandbreak (MethodChannel + EventChannel)
  probe/         HandbreakProbe
  utils/         ResolutionCalculator, QualityMapper, Validation
android/src/main/kotlin/com/handbreak/handbreak/
  HandbreakPlugin.kt, MediaProbe.kt, VideoTranscoder.kt, ImageTranscoder.kt,
  HardwareCapabilitiesProvider.kt, ResolutionHelper.kt, JobManager.kt
ios/Classes/HandbreakPlugin.swift   // AVFoundation + VideoToolbox + ImageIO
test/unit/                          // option validation, preset mapping, codec selection, resolution, progress
example/                            // picker → probe → preset → compress with progress & cancel
ARCHITECTURE.md                     // HandBrake analysis + dependency matrix
```

---

## Testing & benchmarks

```bash
flutter test                          # 50 unit tests (resolution, quality mapper, presets, progress, caps, probe)
flutter analyze                       # lints via flutter_lints
```

Integration fixtures (MP4/MOV/MKV, 4K/1080p/portrait/VFR/no-audio/multi-audio/HDR/corrupt, JPEG/PNG/WebP/HEIC/alpha/EXIF) are described in `ARCHITECTURE.md §4`. A benchmark harness measuring encode time, size, CPU, peak RSS, HW vs SW delta is scaffolded as Phase 4 (see `ROADMAP` in `THIRD_PARTY_LICENSES.md`).

---

## Licensing

- **This package (`handbreak`): MIT** — see [`LICENSE`](LICENSE).
- **HandBrake**: GPL-2.0. This package *studies* HandBrake's architecture and re-implements concepts clean-room in Dart/Kotlin/Swift. No GPL source is copied. HandBrake's license is documented in [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).
- **FFmpeg**: not bundled by default. If you add an FFmpeg LGPL build, build with `--disable-gpl` to keep redistribution permissive. Shipping `libx264`/`libx265` under GPL requires a compatibility review — not included.
- **Platform codecs** (`MediaCodec`, `VideoToolbox`, `AVFoundation`) are permissive and hardware-backed.

See `THIRD_PARTY_LICENSES.md` for the full matrix and build flags.

---

## Roadmap (phases)

- **Phase 1 (this release)**: H.264 MP4 + AAC, CQ & ABR, resize, progress/cancel, Android+iOS, probe, unit tests, presets
- **Phase 2**: H.265/HEVC, hardware detection polish, VFR handling, crop/pad/rotate/scale GL path
- **Phase 3**: AV1/VP9, HDR passthrough, WebP/HEIC/AVIF image paths, EGL filter shaders
- **Phase 4**: PSNR/SSIM/VMAF bench, smarter auto strategy, battery/thermal-aware scheduling, native instrumented tests

---

## Contributing

PRs welcome. Please run `flutter analyze && flutter test` and include a fixture description for any new media handling.

HandBrake's source: https://github.com/HandBrake/HandBrake — study, don't copy.
Issues: https://github.com/your-org/flutter_handbreak/issues

---

## v0.2.0 — how it works now (plan-driven)

Policy is resolved once in Dart and executed natively — see [`ARCHITECTURE.md §5`](ARCHITECTURE.md) and the audit in [`PRODUCTION_REVIEW.md`](PRODUCTION_REVIEW.md):

```dart
final job = await VideoCompressor.start(input, options: myOptions);
// internally: probe → HardwareCapabilities → EncodePlanResolver.resolve()
//            → natives execute ResolvedPlan (no cross-platform drift)
```

**Guarantees:**
- Audio is never silently dropped: passthrough when safe, AAC transcode otherwise (`audio.mode`).
- Framerate limiting is drop-only at decoder-output PTS — never duplicates frames.
- Unsupported container/codec combos fall back with an explicit note in `result.qualityWarning`
  (e.g. MKV → MP4 on both platforms; Opus-in-MP4 → AAC on Android).
- `usedHardwareAcceleration` reflects real probes (`MediaCodecList.isSoftwareOnly` /
  `VTCompressionSession` hardware-required). On iOS, `softwareOnly` is recorded as
  unenforceable rather than faked — Apple's exporter picks its encoder.
- Output is re-probed before success is reported; partial files are `.tmp` + atomic rename.
