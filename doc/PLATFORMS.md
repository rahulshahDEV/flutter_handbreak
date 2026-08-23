# Platform Support

## Codec & container matrix

| Capability | Android | iOS |
|---|---|---|
| H.264 encode | MediaCodec `video/avc` (HW/SW) | VideoToolbox (HW) / AVFoundation |
| H.265/HEVC encode | MediaCodec `video/hevc` (API 24+) | VideoToolbox (iOS 11+) |
| AV1 encode | MediaCodec `video/av01` (Android 14+) | VideoToolbox (iOS 17+) |
| VP9 encode | MediaCodec `video/x-vnd.on2.vp9` | not exposed (reported false) |
| MP4 mux | MediaMuxer (MPEG-4) | AVAssetExportSession |
| MOV | — (falls back to MP4) | AVAssetExportSession `.mov` |
| WebM | MediaMuxer (VP8/VP9 + Opus/Vorbis only) | — (falls back to MP4) |
| Image JPEG/PNG/WebP | BitmapFactory + Bitmap.compress | CGImageSource/Destination |
| Image HEIC/HEIF | — (falls back to JPEG + warning) | CGImageDestination `public.heic` |
| Image AVIF | — (falls back to JPEG + warning) | where ImageIO supports it |
| Probe | MediaExtractor + MediaFormat | AVURLAsset + CMFormatDescription |

Capability checks are runtime probes (`MediaCodecList` / `VTCompressionSession`),
never name-string assumptions.

## Hardware acceleration policy

```
hardwareOnly  → HW required; throws HardwareEncoderUnavailableException if absent
auto          → HW when available; transparent software fallback
hardwarePreferred → HW first, fallback allowed
softwareOnly  → software path
```

`result.usedHardwareAcceleration` reports what was **actually used**.
Known iOS honesty note: `AVAssetExportSession` picks Apple's encoder internally;
`softwareOnly` cannot be enforced there and is recorded in `qualityWarning`
rather than faked. Android reports the real `isSoftwareOnly` status of the
selected encoder.

## Safety guarantees

- **Streaming I/O** — no video is ever loaded into memory; bounded queues
  (cap 64 encoded samples) with producer backpressure.
- **Temp files** — unique per job: `<output>.hbtmp.<jobId>`; deleted on
  success/failure/cancel; atomic rename on commit.
- **Input is never modified**; input == output rejected; existing outputs are
  only replaced with `overwriteExisting: true`.
- **Output validated** after encode: exists, non-empty, re-probed, duration
  within tolerance — before commit. Exit code 0 alone is never trusted.
- **Cancellation** — cooperative, idempotent: atomic flag → codec stop →
  temp delete → exactly one terminal result.
- **Watchdog** — no pipeline progress for 30 s fails the job loudly instead
  of hanging.
- **Main-thread safety** — no native I/O, probing, or capability probes run on
  the Flutter/plugin main thread; job start never blocks.
- **Engine detach** cancels all running jobs (battery/resource safety).

## Requirements

- Android `minSdk 21`, ARM64/ARMv7/x86_64 (no NDK binaries shipped — platform APIs only)
- iOS 13+, Swift 5, AVFoundation/VideoToolbox/ImageIO
- No FFmpeg, no GPL binaries, no large native dependencies (~96 KB package archive)

## Known limitations

- Image HEIC/AVIF encode falls back to JPEG with a warning on devices without support.
- iOS `softwareOnly` is unenforceable (documented above).
- Progressive JPEG not yet supported.
- Filters beyond scale/crop/rotate/grayscale are validated but no-op until Phase 2.
- Multiple audio tracks: first track is used; others are ignored (documented behavior).
- Concurrent jobs: max 1 active + 8 queued; excess jobs fail fast with `QUEUE_FULL`.
- Images larger than 100 MP without explicit `maxWidth/maxHeight` fail safely
  with a clear message instead of risking OOM.

## UNVERIFIED on real devices

These behaviors are implemented and statically validated, but this package has no
physical-device test lane — they must be verified on real hardware before the
10/10 claim:

1. **iOS orientation** — the single-rotation fix (track transform zeroed when a
   videoComposition is used) needs A/B verification on 90°/180°/270° + mirrored
   sources on physical iPhones.
2. **iOS `usedHardwareAcceleration`** — reports hardware *capability* (Apple's
   exporter picks its encoder internally); actual HW-vs-SW use per device unproven.
3. **Android HW encoders per OEM** — MediaCodec behavior varies by vendor
   (Samsung/Qualcomm/MTK/Pixel); stall watchdogs cover pathological cases but
   per-OEM encode quality/size variance is unmeasured.
4. **VFR edge cases** — fractional/VFR sources validated by design, not by
   fixture runs on devices.
5. **HDR/10-bit passthrough** — detected in probe; encode-side behavior
   (tone-map or preserve) is not device-verified.
6. **Thermal/battery** — default concurrency is conservative (1 active job) but
   no thermal profiling has been run on physical devices.
7. **Disk-full mid-encode** — write failures surface as controlled errors; an
   actual low-storage device run has not been performed.
8. **Real-media fixture matrix** — MP4/MOV/MKV/WebM/VFR/4K fixtures are defined
   in the plan but not executed on hardware in CI (no runner).