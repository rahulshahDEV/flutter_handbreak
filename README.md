# flutter_handbreak

[![pub.dev](https://img.shields.io/pub/v/flutter_handbreak)](https://pub.dev/packages/flutter_handbreak)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Lightweight, quality-first video & image compression for Flutter (Android + iOS).**

Inspired by [HandBrake](https://handbrake.fr) (GPL-2.0) — its pipeline, quality model
and presets were studied and re-implemented clean-room. No HandBrake code is bundled.

```dart
import 'package:flutter_handbreak/flutter_handbreak.dart';

final result = await FlutterHandbreak.compressVideo('/path/in.mp4', quality: 80);
print('${result.compressionPercentage.toStringAsFixed(1)}% smaller');
```

## Features

- **Video**: H.264 / H.265 / AV1 / VP9 · MP4 / MOV / WebM / 3GP · constant-quality & bitrate modes
- **Image**: JPEG / PNG / WebP everywhere; HEIC / AVIF where the device encoder
  exists (falls back to JPEG with an explicit warning) · EXIF-aware · alpha-preserving
- **Hardware accelerated**: MediaCodec (Android) + VideoToolbox (iOS), software fallback
- **One-liner API** with a unified 0–100 quality scale, or full control via options
- **Progress, cancellation, presets, probing, capabilities**
- **Safe by design**: streaming I/O, bounded memory, temp-file + atomic commit, output re-validation

## Install

```yaml
dependencies:
  flutter_handbreak: ^1.0.2
```

Android `minSdk 21` · iOS 13+ · no FFmpeg or large native binaries bundled (measured: ~102 KB archive, zero `.so` in the Android AAR).

## Quick start

### Compress a video

```dart
final job = await FlutterHandbreak.compressVideoWithOptions(
  '/path/in.mp4',
  const VideoCompressionOptions(maxWidth: 1920, maxHeight: 1080),
  onProgress: (p) => print('${(p.progress * 100).toStringAsFixed(0)}%'),
);
final r = await job;
```

### Compress an image

```dart
final r = await FlutterHandbreak.compressImage(
  '/path/photo.jpg',
  quality: 82,
  maxSide: 2048,       // never upscales; keeps original if output would be larger
);
```

### Probe & capabilities

```dart
final info = await FlutterHandbreak.probe('/path/clip.mov'); // streams, rotation, HDR, fps…
```

## Documentation

| Doc | Contents |
|---|---|
| [API reference](doc/API.md) | Every class, option, result & error |
| [Quality model](doc/QUALITY.md) | Rate control, presets, filters, codec-aware CRF |
| [Platforms](doc/PLATFORMS.md) | Codec/container matrix, hardware, safety, limitations |
| [Architecture](doc/ARCHITECTURE.md) | Pipeline design & HandBrake analysis |
| [Migration roadmap](doc/MIGRATION.md) | Planned C++/FFI core |

## Verification status

- Verified on this machine: `flutter analyze` clean · 94 Dart unit tests ·
  16 Android JVM tests (Gradle) · Android release AAR build · iOS Swift
  typecheck · `dart pub publish --dry-run` clean.
- **UNVERIFIED — requires physical devices**: real-media fixture matrix
  (see `integration_test/README.md`), per-OEM hardware behavior, iOS
  orientation A/B, VFR/HDR edge cases, thermal/battery profiling, and
  HW-vs-SW benchmarks. This package does **not** claim device-tested status.
- Reproducible local verification: `tool/verify.sh`.

## License & credits

- Package code: **MIT** — see [LICENSE](LICENSE) and [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES.md).
- **Inspired by HandBrake** ([handbrake.fr](https://handbrake.fr), GPL-2.0). Concepts only —
  pipeline stages, CQ-vs-ABR rate control, preset intent, bounded queues. No GPL code copied.
- Platform codecs (MediaCodec / VideoToolbox / AVFoundation / ImageIO) are permissive.