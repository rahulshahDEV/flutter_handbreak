# Third-Party Licenses & Compatibility

## This package

`handbreak` (Dart/Kotlin/Swift glue, pipeline orchestration, option models, tests, example) is **MIT** — see `LICENSE`.

## HandBrake

- Source: https://github.com/HandBrake/HandBrake
- License: **GPL-2.0** (`COPYING` at repo root).
- Usage in this package: **studied as engineering reference only**. No GPL source is copied into `handbreak`. Pipeline concepts (probe → demux → decode → sync → filter chain → encode → mux), CQ vs ABR rate-control model, FIFO sizing, HW fallback policy, preset *intent* and validation lifecycle are re-implemented clean-room in permissive languages.
- If you vendor HandBrake patches or link `libhb` directly, your distribution becomes GPL-2.0. Do not do this unless you intend GPL.

## FFmpeg

- https://ffmpeg.org — **LGPL-2.1 or GPL-2.0** depending on build flags.
- `handbreak` **does not bundle FFmpeg by default**. The default engines are:
  - Android: `MediaExtractor` / `MediaCodec` / `MediaMuxer` / `Bitmap`
  - iOS: `AVFoundation` / `VideoToolbox` / `ImageIO` / `CoreGraphics`
- If you add FFmpeg for extra probe/codec coverage:
  - Build with `--disable-gpl --enable-version3` (or at minimum `--disable-gpl`) to stay LGPL.
  - Document the FFmpeg version and configuration in your app's legal notices.
  - Do **not** enable `--enable-libx264` / `--enable-libx265` in an LGPL build — those force GPL.

## x264 / x265 / SVT-AV1 / libvpx

- `libx264` (GPL-2.0, commercial license available), `libx265` (GPL-2.0, commercial), `libaom`/`SVT-AV1` (BSD/Apache), `libvpx` (BSD).
- Not bundled. If you link GPL codecs, your app's binary distribution may become GPL — obtain a commercial license or avoid bundling.

## Platform & support libs

- AndroidX `annotation`, `exifinterface` — Apache-2.0.
- `plugin_platform_interface`, `flutter` SDK — BSD.
- iOS `AVFoundation`, `VideoToolbox`, `ImageIO` — Apple system frameworks, permissive for app use.

## Dependency matrix (recap from ARCHITECTURE.md)

| Capability | Android | iOS | License |
|---|---|---|---|
| Probe/demux | MediaExtractor | AVURLAsset | Permissive |
| H.264 HW | MediaCodec video/avc | VideoToolbox H264 | Permissive |
| H.265 HW | MediaCodec video/hevc | VideoToolbox HEVC | Permissive |
| AV1 HW | MediaCodec video/av01 (14+) | VideoToolbox AV1 (17+) | Permissive |
| SW codecs | (opt-in FFmpeg LGPL) | (opt-in FFmpeg LGPL) | LGPL if --disable-gpl |
| Mux | MediaMuxer | AVAssetWriter | Permissive |
| Filters (scale/crop) | Surface + MediaCodec input Surface | AVMutableVideoComposition / CoreImage | Permissive |
| Image | Bitmap + ExifInterface | CGImageDestination/Source | Permissive/Apache-2.0 |

## Verifying your build stays permissive

```bash
# If you add FFmpeg, assert the build flag:
ffmpeg -version 2>&1 | grep -q "enable-gpl" && echo "ERROR: GPL FFmpeg bundled" || echo "LGPL OK"
```

Add this check to CI. Never silently ship a GPL binary in a package advertised as permissive.

## Notices to include in your app

If you distribute an app using `handbreak`:

1. Include this package's MIT `LICENSE`.
2. If you added FFmpeg LGPL, include FFmpeg's `LICENSE`/`COPYING.LGPL*` and state the version/config.
3. HandBrake itself is not distributed, so its GPL does not apply — but credit HandBrake's engineering in your docs if you describe the pipeline inspiration.

