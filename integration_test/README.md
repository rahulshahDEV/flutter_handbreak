# Integration Test Lane (real devices / emulators)

Requires physical devices (or an emulator) + real media fixtures. This lane is
NOT run automatically — GitHub Actions is disabled on this repo (billing), and
no hardware runner exists. It is ready to execute with:

```bash
flutter test integration_test -d <device-id>
```

## Fixtures

Place fixtures in `tool/fixtures/` (gitignored, not committed — licensing):

| File | Purpose |
|---|---|
| `h264_1080p.mp4` | H.264 + AAC, CFR 30 |
| `h265_1080p.mp4` | HEVC + AAC |
| `portrait_rot90.mov` | portrait with rotation metadata |
| `vfr_60.mkv` | VFR source, 60 fps nominal |
| `4k_hdr.mp4` | 4K HDR10 (if available) |
| `no_audio.mp4` | video without audio |
| `multichannel.mkv` | AAC 5.1 |
| `truncated.mp4` | intentionally truncated (corrupt) |
| `zero_byte.mp4` | 0-byte file |
| `photo.jpg` / `photo.png` / `photo.webp` / `photo.heic` | images |
| `huge.jpg` | >100 MP image (decompression-bomb case) |
| `exif_rotated.jpg` | EXIF orientation 6 (90° CW) |

Generate H.264/AAC fixtures with any encoder, or export from HandBrake itself
(desktop) — HandBrake is the reference for quality comparison too.

## What the lane verifies

- probe correctness (duration, streams, rotation, HDR flag)
- compress success + output validation (re-probe, duration tolerance)
- portrait stays portrait; rotation not doubled
- VFR/CFR/fps-cap behavior (drop-only)
- audio preserved (passthrough + transcode), A/V sync within tolerance
- keepOriginalIfSmaller returns wasKeptOriginal
- corrupt/truncated/zero-byte inputs fail with typed errors, never crash
- cancellation during decode/encode/mux → CancelledCompressionException + temp cleanup
- dispose during job; plugin-detach simulation
- many rapid jobs (queue bounds, QUEUE_FULL)
- huge image fails safely with INVALID_INPUT (or succeeds with maxWidth)
