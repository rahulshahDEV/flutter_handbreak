# Quality Model

> HandBrake-aligned: **constant-quality first**. Output size is an outcome,
> not a guarantee. Simple scenes get less bitrate, complex scenes get more.

## Unified 0–100 scale (facade)

`FlutterHandbreak.compressVideo(quality: q)` maps to discrete levels:

| Quality | Level | H.264 CRF | H.265 CRF | AV1 CQ | VP9 CQ |
|---|---|---|---|---|---|
| 90–100 | veryHigh | 18 | 20 | 28 | 30 |
| 75–89 | high | 20 | 22 | 32 | 34 |
| 60–74 | medium | 23 | 25 | 38 | 40 |
| 40–59 | low | 26 | 28 | 44 | 46 |
| 0–39 | veryLow | 30 | 32 | 50 | 52 |

Lower CRF = higher quality = larger file. Ranges are codec-specific —
`QualityMapper.validRangeFor(codec)` is H.264/H.265 `0–51`, AV1/VP9 `0–63`.
**Never assume a CRF value is portable across codecs.**

## Rate control modes

- **Constant quality** (default): `RateControl.constantQuality(VideoQuality.medium)`
  or explicit `RateControl.constantQualityValue(22.0)`.
  On MediaCodec this maps to `BITRATE_MODE_CQ` where the device supports it
  (ceiling bitrate still set; result reports honest `usedHardwareAcceleration`).
- **Average bitrate**: `RateControl.averageBitrate(2500)` — `twoPass` available
  but disabled by default on mobile (thermal/battery).
- **Advanced escape hatch**: `AdvancedEncoderOptions(crf: 22, preset: 'slow', tune: 'film')`
  — validated against the codec's valid range.

## Presets

Curated, HandBrake-inspired intent (not copied values):

| Preset | Codec | Container | Max res | Max fps | Audio | HW policy |
|---|---|---|---|---|---|---|
| `fast` | H.264 | MP4 | 1280×720 | 30 | 96k | hardwarePreferred |
| `balanced` | H.264 | MP4 | 1920×1080 | 30 | 128k | auto |
| `highQuality` | H.264 | MP4 | 1920×1080 | — | 160k | auto |
| `smallFile` | H.265 | MP4 | 1280×720 | 30 | 96k | auto |
| `socialMedia` | H.264 | MP4 | 1080×1920 | 30 | 128k stereo | hardwarePreferred |
| `messaging` | H.264 | MP4 | 720² | 30 | 64k mono | hardwarePreferred |
| `web` | H.265 | MP4 | 1920×1080 | — | 128k | auto |
| `archive` | H.265 | MKV→MP4* | source | — | copy | auto |

\* MKV isn't writable by mobile muxers; falls back to MP4 with an explicit
`qualityWarning` in the result.

## Filters

Composable; canonical order is enforced natively (HandBrake
`sanitize_filter_list_pre/post` ordering):

```
crop → scale → pad → rotate → deinterlace → denoise → sharpen → grayscale
```

```dart
filters: [
  const CropFilter(top: 0, bottom: 0, left: 0, right: 0),
  const ScaleFilter(width: 1280, height: 720),
  const DenoiseFilter(strength: DenoiseStrength.light),
]
```

Expensive filters are never enabled implicitly — only when requested.
Current native support executes scale/crop/rotate/grayscale paths (platform
compositions / surfaces); deinterlace/denoise/sharpen are validated and
no-op until the Phase-2 GL shader pass ships.

## Honest fallbacks (all surfaced in `result.qualityWarning`)

- Container not writable on platform → MP4
- Opus in MP4 (Android) → AAC
- Audio copy unsafe → transcode
- HW encoder unavailable → software (`usedHardwareAcceleration = false`)
- HEIC/AVIF encode unavailable → JPEG (reported, never lied about)
- Source already heavily compressed → warning that recompression saved little