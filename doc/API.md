# API Reference

> Entry point: `package:flutter_handbreak/flutter_handbreak.dart`
> (legacy alias: `package:flutter_handbreak/handbreak.dart`)

## Facade — one-liners

```dart
class FlutterHandbreak {
  static Future<CompressionResult> compressVideo(
    String inputPath, {
    int quality = 80,            // 0–100 unified scale → VideoQuality bucket
    VideoPresetId? preset,       // overrides quality when set
    String? outputPath,
    void Function(CompressionProgress)? onProgress,
  });

  static Future<CompressionResult> compressVideoWithOptions(
    String inputPath,
    VideoCompressionOptions options, {
    String? outputPath,
    void Function(CompressionProgress)? onProgress,
  });

  static Future<CompressionResult> compressImage(
    String inputPath, {
    int quality = 82,
    int maxSide = 2048,
    ImageFormat format = ImageFormat.auto,
    String? outputPath,
  });

  static Future<MediaInfo> probe(String path);
}
```

Quality scale (facade): `90+ veryHigh · 75+ high · 60+ medium · 40+ low · else veryLow`,
each mapped codec-aware to native CRF by `QualityMapper`.

## Low-level API

### VideoCompressor

```dart
// One-shot
final result = await VideoCompressor.compress(
  input,
  options: const VideoCompressionOptions(
    quality: VideoQuality.medium,   // or rateControl:
    maxWidth: 1920,
    maxHeight: 1080,
    maxFrameRate: 30,
    codec: VideoCodec.h264,
    container: VideoContainer.mp4,
    hardwareAcceleration: HardwareAcceleration.auto,
  ),
);

// Long-running job with progress + cancel
final job = await VideoCompressor.start(input, options: opts);
job.progress.listen((p) => print(p));   // real PTS/frame-based progress
final result = await job.result;        // CompressionResult
await job.cancel();                     // idempotent; result throws CancelledCompressionException

// Presets
final result = await VideoCompressor.compressWithPreset(
  input, VideoPresetId.socialMedia,
  override: (base) => base.copyWith(maxWidth: 1280),
);
```

### ImageCompressor

```dart
final result = await ImageCompressor.compress(
  input,
  options: const ImageCompressionOptions(
    quality: 82,
    maxWidth: 2048,
    maxHeight: 2048,
    format: ImageFormat.auto,     // auto → JPEG/PNG (alpha-aware), platform-gated WebP/HEIC/AVIF
    preserveExif: false,
    keepOriginalIfSmaller: true,  // never grow the file
  ),
);
```

### HandbreakProbe

```dart
final info = await HandbreakProbe.probe(path); // MediaInfo
info.primaryVideo  // VideoStreamInfo: width, height, rotation, frameRate, isHdr, codec…
info.primaryAudio  // AudioStreamInfo: sampleRate, channelCount, codec…
info.isPortrait    // rotation-corrected
```

## Models

### VideoCompressionOptions

| Field | Default | Notes |
|---|---|---|
| `codec` | `h264` | `h264 / h265 / av1 / vp9` |
| `container` | `mp4` | `mp4 / mov / mkv` (mkv falls back to mp4 with warning) |
| `rateControl` | CQ medium | see [Quality model](QUALITY.md) |
| `quality` | — | convenience alias for `RateControl.constantQuality` |
| `maxWidth / maxHeight` | — | cap, aspect preserved |
| `targetWidth / targetHeight` | — | explicit size (upscale allowed) |
| `scale` | — | 0–4 factor |
| `frameRateMode` | `sameAsSource` | `sameAsSource / variable / constant` |
| `maxFrameRate` | — | drop-only capping, never duplicates frames |
| `audio` | AAC 128k encode | `AudioOptions(mode: encode/copy/remove)` |
| `hardwareAcceleration` | `auto` | `auto / hardwarePreferred / hardwareOnly / softwareOnly` |
| `filters` | — | composable filter list, canonical order |
| `advanced` | — | codec-specific CRF/preset/tune/profile/level |
| `keepOriginalIfSmaller` | false | return original if output would be larger |
| `overwriteExisting` | false | allow replacing an existing output |

### RateControl

```dart
RateControl.constantQuality(VideoQuality.medium)  // default — size is an outcome, not a target
RateControl.constantQualityValue(22.0)            // explicit codec-specific CRF/QP
RateControl.averageBitrate(2500, twoPass: false)  // ABR mode
```

### CompressionResult

`inputPath, outputPath, originalSizeBytes, outputSizeBytes, savedBytes,
compressionRatio, compressionPercentage, durationMs, usedHardwareAcceleration,
codec, container, qualityWarning?, wasKeptOriginal, outputMediaInfo?`

### CompressionProgress

`progress (0–1), processedDurationMs, totalDurationMs, encodedFrames, totalFrames,
currentFps, estimatedRemaining, stage`

### CompressionJob

`id, Stream<CompressionProgress> progress, Future<CompressionResult> result, cancel()`

## Errors

All errors extend `HandbreakException`:

| Error | Meaning |
|---|---|
| `InvalidInputException` | file missing/empty, input == output |
| `UnsupportedFormatException` | no decodable stream / format |
| `CodecUnavailableException` | codec absent on device |
| `HardwareEncoderUnavailableException` | `hardwareOnly` requested, HW unavailable |
| `OutputCreationException` | destination exists (no overwrite) / unwritable |
| `CancelledCompressionException` | job cancelled |
| `EncodingException` | encode/mux/validation failure (generic) |
| `InsufficientStorageException` / `OutOfMemoryException` | resource limits |
| `CompressionTimeoutException` | native watchdog/stall — codec stopped progressing, job terminated |

Every error carries `nativeCode` + `nativeMessage` for diagnostics.