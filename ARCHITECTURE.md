# Handbreak Architecture — HandBrake-inspired Flutter media SDK

> This document captures the thorough analysis of **HandBrake's `libhb`** (commit 2026-08-22, depth-1 clone from `https://github.com/HandBrake/HandBrake`) and how that analysis drives the architecture of the Flutter package `handbreak`.

--------------------------------------------------------------------

## 1. HandBrake pipeline — what was found

### 1.1 Overall flow implemented in `libhb/work.c:do_job` (line ~1738)

```
SOURCE FILE / STREAM
  → SCAN / PROBE         scan.c → hb_title_t, hb_geometry_t, vrate, color info, streams
  → READER               reader.c  demux; one thread; fifo_in→ raw AVPackets
  → AUDIO/SUBTITLE DEC   one work_object per stream, each on its own thread (fifo_in / fifo_raw / fifo_sync / fifo_out)
  → VIDEO DECODER        decavcodec.c  (AVCodec + optional hwaccel context)
  → SYNC                 sync.c  aligns A/V by PTS, resolves VFR→CFR, estimates progress
  → AUDIO FILTER CHAIN   per-audio hb_filter_object_t chain (resample/remap/compressor)
  → VIDEO FILTER CHAIN   ordered hb_filter_object_t list:  crop → scale → pad → rotate
                                                    → deinterlace/decomb/detelecine
                                                    → denoise (nlmeans) → sharpen → grayscale
                                                    → colorspace → avfilter bridge
                          Each filter runs on its own thread (filter_loop) connected by FIFOs.
  → VIDEO ENCODER        encx264.c / encx265.c / encsvtav1.c / encavcodec.c (AVCodec passthrough for HW: nvenc/qsv/vaapi/vce)
  → AUDIO ENCODER        encavcodecAudio / encavsub etc. (one per audio track)
  → MUXER                muxcommon.c / muxavformat.c  (ffmpeg AVFormatContext; owned by mux thread)
  → OUTPUT FILE
```

`do_job` builds `job->list_work` and `job->list_filter` sequentially, then launches **one thread per work object** via `hb_thread_init(..., hb_work_loop)` (work.c:2254) and one `filter_loop` per filter (work.c:2267). The muxer is the terminal consumer (`fifo_out`). Threads block on FIFO full/empty with condition variables; the FIFOs provide back-pressure.

### 1.2 FIFO & buffer model (`libhb/fifo.c`, `libhb/work.c:40-45`)

| Constant | Value | Purpose |
|---|---|---|
| `FIFO_SMALL` | 16 | demux→decode, decode→sync; wake=15 |
| `FIFO_LARGE` | 32 | sync→encoder, render→mux; wake=16 |
| `FIFO_UNBOUNDED` | 65536 | subtitle decoded lines (unbound to avoid deadlock; see work.c:1998-2012 comment) |
| `BUFFER_POOL_MAX_ELEMENTS` | 32 | per size-class; first pool 320 entries. Size classes 1<<10..1<<25 (fifo.c:75-131). Pools 0..9 alias pool[10]. |

`hb_buffer_t` allocations are **pooled** by power-of-two size class (`hb_buffer_init` picks `pool = log2(size)`). FIFO is bounded + blocking; `hb_fifo_push` blocks when full, `hb_fifo_get_wait` blocks when empty. This bounds peak memory while avoiding busy-poll.

**Mobile mapping:** On Android/iOS we must not replicate a threaded FIFO ring for real-time throughput (mobile prefers fewer threads to save battery). We keep the *concept* — separate bounded queues between pipeline stages — but collapse to **3 native worker threads**: `probe` (short-lived), `transcode` (holding decoder→filter→encoder→mux), `io` (mux file I/O). Within `transcode`, MediaCodec/VideoToolbox already own internal queues; we emulate HandBrake's FIFO watermarks via `MediaCodec.dequeue*` timeouts and bounded `LinkedBlockingQueue` for audio frames.

### 1.3 Probe (`scan.c`)

`scan.c` reads the container with `hb_stream` + libavformat, emits `hb_title_t` per title plus `hb_geometry_t {width,height,par}` and `hb_rate_t vrate` (num/den). It detects rotation, color primaries/transfer/matrix, chroma location, HDR (dovi/hdr10plus), bit depth, scan type (progressive/interlaced), and per-stream codec params. The queue UI (`batch.c`) groups titles.

**Mobile mapping:** Probe must run **before encode** to derive safe defaults. On Android we use `MediaExtractor` + `MediaFormat` (no FFmpeg required); on iOS `AVAssetTrack` + `CMFormatDescription`. Both expose geometry/rotation/color but HDR needs special handling — we detect HDR and preserve or explicitly tonemap; we never silently crush HDR→SDR (HandBrake's `sanitize_filter_list_post` and `correct_framerate` are the analogues).

### 1.4 Frame-rate handling (`libhb/vfr.c`, `libhb/sync.c`, `work.c:1928-1932`)

- `job->vrate` holds the target rate; `job->orig_vrate` preserves source rate.
- `correct_framerate(interjob, job)` enforces preset/FPS limits.
- `hb_vfr` filters convert; `cfr` flag forces constant framerate by duplicating/dropping. HandBrake **defaults to constant** at source rate unless `vfr` is requested or a max-fps is set. VFR passthrough is explicit.
- Time base is normalized to `90000` (work.c:1842) and `hb_reduce` cleans fractions.

**Mobile mapping:** We expose `FrameRateMode {sameAsSource, variable, constant}` with `maxFrameRate`. Default = `sameAsSource` → `cfr=0`; `constant` or a `maxFrameRate` lower than source forces frame dropping before encode. We avoid unnecessary duplication.

### 1.5 Rate control (`encavcodec.c:646-800`, `encx264.c:537`, `common.h:790`)

- `HB_INVALID_VIDEO_QUALITY (-1000.0)` means ABR/bitrate mode; any other value is CQ.
- x264 path sets `param.rc.i_rc_method = X264_RC_CRF` and `rf_constant = job->vquality`.
- x265 similarly maps via `x265_param_parse(..., "crf", ...)`.
- `encavcodec.c` dispatches per-codec: libvpx `FF_QP2LAMBDA * vquality`, `crf` for software, `cq` (plus `init_qpI/B ±2`) for NVEnc, `global_quality` CLIP[1..51] for QSV, `qp` for VAAPI. Two-pass is separate `HB_PASS_ENCODE_ANALYSIS` job.
- Quality **ranges are NOT universal** — CQ 20 for x264 ≠ CQ 20 for x265/VP9/AV1.

**Mobile mapping:** We model `RateControl.constantQuality(VideoQuality)` and `RateControl.averageBitrate(kbps)` + optional `twoPass`. `VideoQuality` is discrete (`veryHigh/high/medium/low/veryLow`) that is **codec-aware mapped** to native CRF/QP values per encoder spec. Users may also supply a codec-specific numeric CRF via `AdvancedEncoderOptions`. Default is `medium` → CQ.

### 1.6 Hardware acceleration (`work.c:1772-1834`, `hwaccel.c`, `qsv_common.c`, `nvenc_common.c`, `vaapi_common.c`, `vce_common.c`)

HandBrake's rule (work.c:1808-1820):
```c
if (hb_hwaccel_can_use_full_hw_pipeline(hwaccel, list_filter, vcodec, rotation, colorRangeMismatch))
    job->hw_accel = hwaccel;  // zero-copy GPU frame stays on device
else if (hw_decode & HB_DECODE_FORCE_HW)
    job->hw_accel = hwaccel;  // decode on GPU, download for filters, re-upload for encode
```
Filters like crop/scale can execute on GPU only for approved whitelists; rotation/color-range mismatch forces CPU. `hb_hwaccel_hw_device_ctx_init` creates the device context.

**Mobile mapping — critical nuance:** Documentation says decode/filter/sync/mux may remain CPU even when encode is HW. On mobile we mirror this: **never claim full-GPU pipeline unless the actual encode path uses a hardware encoder**. Detection at runtime:
- Android: enumerate `MediaCodecList.ALL_CODECS`, filter `isEncoder && !isSoftwareOnly` per MIME. `supportsHardwareH264/HEVC/AV1`.
- iOS: `VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)` / `VTCompressionSession` properties (`kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder`).

Selection: `HardwareAcceleration.auto` → try hardware, verify `MediaFormat`/`VTSession` creation succeeds, otherwise silent fallback to software (reporting `usedHardwareAcceleration=false` in result). `hardwarePreferred` / `hardwareOnly` / `softwareOnly` enforce the policy.

### 1.7 Progress & cancellation (`sync.c:3192-3265`, `work.c:67-78`)

- `sync.c:3192`: `p.progress = frame_count / common->est_frame_count` (or `pts_to_start` for partial encodes). Clamped to `[0,1]`.
- The `hb_state_t {state, progress, ...}` is polled; `hb.c:2001` initializes `HB_STATE_WORKING` with 0.0.
- Cancellation: `*job->die = 1` + `*job->done_error` set, then `hb_fifo_close` wakes blocked threads; threads observe `job->done` and exit their `hb_work_loop`. `do_job:cleanup` closes fifos and frees `list_work`.

**Mobile mapping:** Native progress fires **on real decode timestamps** (`presentationTimeUs / durationUs` or `encodedFrames / estimatedTotal`). Dart receives `CompressionProgress` via `EventChannel`; `estimatedRemaining` is `elapsed * (1/progress - 1)`.

### 1.8 Muxing & validation (`muxcommon.c:`, `muxavformat.c`)

Container selection (`FileFormat` enum) determines `AVFormatContext` and codec-tag constraints. After mux, HandBrake re-scans or at least `stat`s the output; mobile must do the same (existence + size + duration + stream count checks) before reporting success — **exit code 0 alone is insufficient**.

### 1.9 Presets (`preset/preset_builtin.json`, `libhb/preset.c`)

6 folder groups → hundreds of presets. Structure per preset: `FileFormat, PictureWidth/Height, PictureKeepRatio, PicturePAR, PictureCropMode, PictureDeinterlace*, PictureDenoise*, VideoEncoder, VideoQualityType (0=ABR/1=CQ/2=CQ), VideoQualitySlider (CRF), VideoFramerate ("auto" or num/den), VideoFramerateMode (pfr/vfr/cfr), AudioList[...] (encoder, mixdown, samplerate, bitrate/quality), Chapters, Optimize`.

Our presets mirror the **intent** (not values): `fast/balanced/highQuality/smallFile/socialMedia/messaging/web`. Each maps to `{codec, container, maxResolution, maxFps, rateControl, audioBitrate, hardwareStrategy}`.

### 1.10 Failure modes the pipeline guards

- Subtitle pipeline deadlock (work.c:1998) → unbounded subtitle FIFOs.
- HW device init failure → silent null-out `hw_accel` + continue on CPU.
- Filter init failure → log & disable that filter, don't abort job.
- Pass-through metadata that would confuse downstream filters is sanitized (`sanitize_dynamic_hdr_metadata_passthru`, `update_dolby_vision_level`).

--------------------------------------------------------------------

## 2. Handbreak (Flutter) architecture

### 2.1 Stack

```
Dart API                    VideoCompressor / ImageCompressor / HandbreakProbe
   |  CompressionOptions, VideoPreset, HardwareCapabilities, MediaInfo, Progress
   v
Platform interface          HandbreakPlatform (plugin_platform_interface)
   |  Pigeon-like typed MethodChannel + EventChannel
   +-------------------------------+
   |                               |
Android (Kotlin)              iOS (Swift)
MediaExtractor probe          AVAssetTrack probe
MediaCodec encode/decode      VideoToolbox encode / AVAssetReader decode
MediaMuxer / MediaFormat      AVAssetWriter / AVAssetExportSession (fallback)
Android Bitmap (image)        CoreGraphics / ImageIO (image)
   |                               |
   +---------------+---------------+
                   |
          Result validation: re-probe output, compare expected geometry/duration
```

No Dart UI isolate does IO-bound transcode. The **entire transcode stays native**, on a bounded `Executor` (Android: `Executors.newFixedThreadPool(1)`; iOS: dedicated `DispatchQueue(label:"handbreak.transcode", qos:.userInitiated)`). Dart sends commands (`compress`, `probe`, `cancel`, `getCapabilities`) over `MethodChannel("handbreak")`; progress flows back over `EventChannel("handbreak/progress/<jobId>")`.

### 2.2 Native dependency matrix & licensing

| Capability | Android primary | iOS primary | Optional add-on | License note |
|---|---|---|---|---|
| Probe / demux | `MediaExtractor` + `MediaFormat` | `AVURLAsset` + `AVAssetTrack` + `CMFormatDescription` | FFmpeg `libavformat`/`libavcodec` (LGPL 2.1 if built `--enable-gpl=no`) | Using **platform APIs only** keeps package **MIT/BSD-compatible**. FFmpeg is opt-in, documented in `THIRD_PARTY_LICENSES.md`; we never ship GPL binaries by default. |
| H.264 software | FFmpeg/LGPL or OpenH264 | FFmpeg/LGPL or OpenH264 | `libx264` is **GPL** unless commercial license purchased — not bundled | HandBrake bundles x264/x265 under GPL; we **do not** copy their encoders. |
| H.264 HW | `MediaCodec` `video/avc` | VideoToolbox `kCMVideoCodecType_H264` | — | Pure hardware, permissive. |
| HEVC | `video/hevc` MediaCodec (API 24+) | VideoToolbox `kCMVideoCodecType_HEVC` (iOS 11+) | — | Check `isHardwareAccelerated` before advertising. |
| AV1 | `video/av01` MediaCodec (Android 14+) | VideoToolbox AV1 (iOS 17+) | libaom/SVT-AV1 LGPL | Fallback to SW with warning if unsupported. |
| Mux MP4 | `MediaMuxer` | `AVAssetWriter` | — | `MediaMuxer` produces `mp4`; MOV produced via ImageIO/AVFoundation path. |
| Filters (crop/scale/pad/rotate) | OpenGL surface + `MediaCodec` input surface | CoreImage / `AVMutableVideoComposition` | libavfilter only if FFmpeg enabled | Minimal CPU/GPU roundtrips; `Surface` path avoids YUV→RGB→YUV. |
| Image JPEG/PNG | `Bitmap.compress` + `ExifInterface` | `CGImageDestination` + `CGImageSource` | — | EGL-safe, no native alloc growth. |
| Image WebP/HEIC/AVIF | `Bitmap` (API 30+ WebP lossless) / `HeifWriter` | `AVFileType.heic` / `UTType.avif` | libwebp/libheif | Presence gated by OS version. |

**Licensing rule we enforce:** HandBrake is **GPL-2.0**; the knowledge (pipeline design, CRF-vs-ABR model, FIFO sizing, HW fallback policy) is studied and **re-implemented clean-room** in Kotlin/Swift. No GPL source is copied. Any future FFmpeg bundle must be built with `--disable-gpl` to stay LGPL; the build flag is asserted in CI.

### 2.3 Media pipeline — concrete stages

Each stage is a pure function/object with a defined I/O type, individually unit-testable in Dart (math/policy) and in native instrumented tests (codec behavior).

```
Video:
  Input(String path)
   → Probe → MediaInfo (geometry incl. rotation-corrected width/height, duration, fps, streams, hdr, color, bitrateEst)
   → ResolveConfig (MediaInfo × CompressionOptions × HardwareCapabilities → ResolvedEncodeConfig)
       - picks final width/height preserving PAR unless allowStretch
       - picks frame rate mode (sameAsSource/variable/constant) respecting maxFrameRate
       - picks rate-control params via QualityMapper(codec, VideoQuality → native CRF/QP/targetBitrate)
       - picks encoder (HW→SW fallback)
   → Demux (MediaExtractor / AVAssetReader)
   → Decode (MediaCodec decoder or passthrough if HW input Surface)
   → Normalize (rotation metadata → transpose matrix; color-range fixup)
   → Filter chain: Crop → Scale (Lanczos/bilinear per preset) → Pad → Rotate → Deinterlace → Denoise...
   → Color/pixel convert (surface handles YUV; no manual AVFrame)
   → Video encode (MediaCodec / VTCompressionSession with resolved params)
   → Audio (parallel): decode → resample/remap → encode AAC/Opus or passthrough
   → Mux (MediaMuxer / AVAssetWriter) — interleaves A/V by PTS
   → Validate → re-probe output file & compare vs expected
   → Output (CompressionResult)

Image:
  probe → {w,h,orientation,exif,hasAlpha,colorSpace}
   → resolve (maxW/H, format=auto→best, quality)
   → decode (Bitmap / CGImage)
   → orientation correction
   → resize (preserve aspect, respect EXIF)
   → encode (JPEG/PNG/WebP/HEIC) with chroma/alpha handling
   → validate (compressedSize < originalSize else policy: keep smaller or return original)
```

### 2.4 Error model

Mirrors HandBrake's `*job->done_error` categories but as typed Dart exceptions:
`InvalidInputException`, `UnsupportedFormatException`, `CodecUnavailableException`, `HardwareEncoderUnavailableException`, `OutputCreationException`, `EncodingException`, `CancelledCompressionException`, `InsufficientStorageException`, `OutOfMemoryException`. Each carries `nativeCode`, `nativeMessage` (sanitized), and `isRecoverable`.

### 2.5 Concurrency, memory, temp files

- `maxConcurrentJobs` caps native executor size (default **1 on mobile** — two simultaneous encodes overheat and OOM). A `Semaphore`-like gate queues Dart `start()` calls.
- No whole-file buffering: decode is streaming; progress callbacks do not allocate per-frame Dart objects.
- Temp files: `context.cacheDir/handbreak/<uuid>.mp4.tmp` with UUID (not predictable), created via `File.createTemp`; on success rename to `outputPath`, on failure/cancel deleted. Original never overwritten unless caller sets `overwriteExisting=true`.
- Every native `MediaCodec`/`VTSession`/`AVAssetWriter` is owned by a `Closeable` scoped to `try/finally`; `onCancel` releases + deletes partial.

### 2.6 API surface (Dart)

Primary entry points operate on **paths** (not bytes). `XFile/File/Uri` overloads are wrappers. `VideoCompressor.compress` is `start().result`; `start()` returns a `CompressionJob` with `Stream<CompressionProgress> progress` and `Future<CompressionResult> result` + `Future<void> cancel()`. Same for `ImageCompressor`. `HandbreakProbe.probe(path)` → `MediaInfo`. `HandbreakCapabilities.get()` → `HardwareCapabilities`.

--------------------------------------------------------------------

## 3. Why decisions differ from HandBrake where they do

- Fewer threads than HandBrake: mobile thermal/battery budget requires serializing encodes; a throughput-optimized 16-thread pipeline on desktop would throttle a phone.
- Platform decoders/muxers over FFmpeg: avoids shipping native binaries per ABI and keeps licensing permissive; FFmpeg remains an **opt-in** probe/fallback layer.
- `VideoQuality` discrete map vs HandBrake continuous `RF slider`: discrete levels prevent users applying x264's 0-51 range to AV1/VP9; advanced users still get numeric `AdvancedEncoderOptions.crf`.

--------------------------------------------------------------------

## 4. Verification plan (matches spec §33-35, 47)

- **Unit** (Dart): option validation, preset→config mapping, `QualityMapper`, `ResolutionCalculator` (aspect/portrait/rotation), `ProgressMath`, `TempFileNaming`.
- **Native instrumented** (per platform): probe MP4/MOV/MKV/portrait/landscape/4K/60fps/VFR/no-audio/multi-audio/HDR/corrupt → verify MediaInfo; encode with each codec+RC mode; filter chain; HW detection; cancellation (thread stops within 2s, partial deleted).
- **Integration** (flutter drive): end-to-end MP4/MOV transcodes, image JPEG/PNG/WebP/HEIC, cancellation, concurrent jobs queue.
- **Benchmark harness** `benchmark/compress_bench.dart` + native microbench measuring encode time, output size, CPU, peak RSS, hardware vs software delta.
- **Quality harness** compares PSNR/SSIM/VMAF vs HandBrake CLI on shared fixtures (not automated on-device, but documented procedure).


--------------------------------------------------------------------

## 5. Production review v2 (2026-08-22)

Full audit in [`PRODUCTION_REVIEW.md`](PRODUCTION_REVIEW.md). Headline changes:

### 5.1 EncodePlanResolver — policy lives in tested Dart

All encode policy is now computed **once** in `lib/src/video/encode_plan_resolver.dart` and shipped to natives as a `ResolvedPlan`:

```
probe(MediaInfo) × VideoCompressionOptions × HardwareCapabilities
        └──► EncodePlanResolver.resolve() ──► ResolvedPlan {
                width,height, sourceFps,targetFps, limitFrameRate,
                container(effective)+fallbackNote,
                useHardware+fallbackNote,
                rateControlMode(cq|cq_value|abr), crf|bitrateKbps,
                audio{mode:passthrough|transcode|remove, codec(effective), bitrate},
                orderedFilters(canonical)
             }
```

Natives are **executors**: Android `VideoTranscoder` consumes `plan`, iOS `VideoPipeline` consumes `plan`. No heuristic drift between platforms; every rule is unit-tested in Dart (`test/unit/encode_plan_resolver_test.dart`).

Documented fallback rules (all surfaced via `result.qualityWarning`):
- container: requested → mp4 → mov; MKV/WebM never silently dropped without note
- audio codec: opus+MP4(android) → AAC; unsafe copy → transcode (+note)
- hardware: auto/hardwarePreferred unavailable → software (+note); hardwareOnly unavailable → typed exception *before* any work

### 5.2 Android pipeline v2

- **Audio preserved** (audit P0-1): passthrough lane (extractor→muxer, sync-frame flags) or AAC-LC transcode lane (decoder→PCM→downmix→encoder), interleaved into muxer strictly by PTS.
- **Framerate gate rewritten** (P0-2): applied at *decoder output PTS*; drop-only (`releaseOutputBuffer(false)`), quarter-interval tolerance, never duplicates frames.
- **ByteBuffer fallback real** (P0-3): YUV_420_888→NV12 converter handles rowStride/pixelStride for semi-planar & planar; feeds encoder via ByteBuffer path when Surface configure fails.
- Bounded memory: interleave queues cap 64; producers stall (codec buffers absorb pressure) instead of unbounded growth.
- 30 s stall watchdog fails loudly instead of hanging.

### 5.3 iOS pipeline v2

- Compiles cleanly (P0-4/P0-5): no inout-capture stream handler, UIKit imported; split into Support/HardwareProbe/MediaProbe/JobManager/VideoPipeline/ImagePipeline files; verified with `swiftc -typecheck` against iphonesimulator SDK.
- **Real HW probes** (P1-1): `VTCompressionSessionCreate` with `RequireHardwareAcceleratedVideoEncoder` per codec; `usedHardwareAcceleration` reports the probe result. Documented honesty note: AVAssetExportSession picks Apple's encoder internally — `softwareOnly` cannot be forced on iOS and is recorded in result notes rather than faked.
- **EXIF orientation correct** (P0-6): decode via transform-aware `CGImageSourceCreateThumbnailAtIndex` (all 8 orientations incl. mirrored), oriented dimensions used for resize math.
- Container fallback (P0-7): non-writable containers → MP4 + note.
- Probe hardened: no force-casts; still-image fallback; HDR/color from format-description extensions.

### 5.4 Dart API v2

- `ImageCompressor.compress` returns typed `Future<CompressionResult>` (P0-8).
- `HandbreakPlatform.ensureInitialized()` replaces private-class string sniffing (P0-9); test injection documented; progress streams self-terminate on done/error (P1-4) preventing channel leaks.
- `VideoCompressor.start` now: validate → probe → resolve caps (best-effort) → resolve plan → native execute(plan).

### Verification status

- `flutter analyze`: 0 errors / 0 warnings
- `flutter test`: **82/82 passing** (resolution, quality mapping, options, presets, progress/caps/media-info, plan resolver incl. container/audio/hw/rc fallbacks, validation helpers, error parity, filter contract)
- Kotlin sources brace-balanced; Swift typechecks against iOS simulator SDK
- Device integration matrix (real MP4/MOV/portrait/4K/VFR/no-audio/multi-audio fixtures) remains the pre-release gate — see §4

--------------------------------------------------------------------

## 6. Audit v3 — correctness hardening (2026-08-23)

Deep safety audit (spec phases 1–2). Every finding verified by reading code.

### 6.1 Real bugs found & fixed

| ID | Severity | Location | Bug | Fix |
|----|----------|----------|-----|-----|
| P0-1 | P0 | `JobManager.kt:44` | `Semaphore.acquire()` on the **caller (main) thread** → ANR risk when concurrency saturated | acquire moved inside worker task; caller always returns instantly |
| P0-2 | P0 | `VideoTranscoder.kt:541` | Decoded PCM **silently dropped** when an audio-encoder input buffer was momentarily unavailable → A/V drift | `feedPcmRetry()` — retry until fed, cancellation-aware |
| P1-1 | P1 | `VideoTranscoder.kt:203` / `VideoPipeline.swift:157` | Temp file `output.tmp` shared across concurrent jobs → collision | job-scoped `output.hbtmp.<jobId>` on both platforms |
| P1-2 | P1 | `VideoTranscoder.kt` | Negative / non-monotonic source PTS passed to `MediaMuxer` → muxer rejection | clamp-to-0 + per-track monotonic write gate |
| P1-3 | P1 | `HandbreakPlugin.kt:50-66` | `probe` + capabilities ran inline on the **platform/main thread** | moved to shared single-thread `ioExecutor` |
| P1-4 | P1 | `HandbreakPlugin.kt:42-46` | Engine detach did **not** cancel running jobs (iOS did) | `onDetachedFromEngine` → `jobManager.shutdown()` (cancels all) |
| P1-5 | P1 | `HandbreakPlugin.kt:78-94` | One raw `Thread {}` per `waitForResult` call | shared `ioExecutor` |
| P1-6 | P1 | `VideoTranscoder.kt:319-344` | Half-created decoder leaked if `configure()` threw inside `.also` | explicit candidate + release-on-failure |
| P1-7 | P1 | `ImageTranscoder.kt:112-117` | Requested heic/avif **silently wrote JPEG** but result claimed `codec: heic` | real fallback: actual format reported + `qualityWarning` note (both platforms) |
| P1-8 | P1 | `ImagePipeline.swift:25` | `Data(contentsOf:)` loaded the **entire image into memory** (OOM on huge files) | URL-based `CGImageSource` (lazy decode) |
| P1-9 | P1 | `VideoPipeline.swift:155` | Unsynchronized `job.task` write vs `JobManager.cancel` read (TSAN race) | `setTask/withTask` under lock |
| P1-10 | P1 | `HardwareProbe.swift` / plugin | VTCompressionSession probes ran on the main thread | dispatched to background |
| P1-11 | P1 | `VideoPipelineSupport.finish` | iOS lacked duration validation (Android had it) | pre-commit temp probe + tolerance check |
| P2-1/2 | P2 | `MediaProbe.kt:122,128` | Int overflow on bitrate / duration for gigantic files | clamped |
| P2-4 | P2 | `ImageTranscoder.kt:166` | EXIF wrote source W/H after resize | actual output dims |
| P2-5 | P2 | `VideoTranscoder.kt` | Native unconditionally deleted existing output | `overwriteExisting` guard (defense-in-depth) |
| P2-6 | P2 | `video_compressor.dart:70-85` | probe + capabilities serial | parallel `(f1, f2).wait` |

### 6.2 Job state machine (spec §5) — both natives

`CREATED → QUEUED → RUNNING → … → COMPLETED`; terminal `CANCELLED | FAILED | DISPOSED`.
Transitions validated (`allowedFrom` sets), idempotent cancel/dispose, exactly-once
completion already guaranteed by `finished` guard. State surfaced in progress payloads
(`state` key) and via `JobManager.stateName` / `Job.state`.

### 6.3 Native architecture decision — why NOT C++/FFI (yet)

The preferred C++-core-with-FFI architecture (spec §3-4) is documented as the **migration
target** but deliberately **not started** in this pass:

- Current Kotlin/Swift + MethodChannel implementation is behaviorally correct for the
  supported feature set (probe → plan → decode → encode → mux → validate) with bounded
  queues, cancellation, and watchdog already in place.
- A C++ core only pays off once the platform adapters (MediaCodec/VideoToolbox) are the
  *thin* layer; porting both pipelines is a multi-stage effort (spec §30) that must be
  staged behind parity tests, not done in one uncontrolled change.
- FFI adds: C ABI ownership rules, per-ABI `.so`/framework packaging, and a new failure
  domain — justified only when the duplicated orchestration is large enough to amortize it.

**Migration roadmap (staged, spec §30 order):**
1. Stage: shared **policy core** (already mostly Dart: `EncodePlanResolver`) — expand to
   audio plan + capability model (spec §23).
2. Stage: **C ABI core** `hb_engine/hb_job` with state machine + queues + temp/commit +
   error taxonomy (pure C++, unit-tested, no platform deps).
3. Stage: Dart FFI bindings (ffigen) behind `HandbreakPlatform` — MethodChannel retained
   for capability/probe fallback.
4. Stage: Android adapter (AAudio/MediaCodec via NDK, async callback mode) then Apple
   adapter (ObjC++ VideoToolbox), replacing Kotlin/Swift orchestration.
5. Stage: parity harness — same fixture matrix on old vs new engine, keep old until green.

Trigger for starting Stage 2: feature demands (filters/GL, HDR, AV1 SW) or measured
orchestration overhead. Do not start on fashion.

### 6.4 Remaining known limitations (honest)

- iOS `usedHardwareAcceleration` reports *hardware encoder availability* (Apple's exporter
  picks its encoder internally; software-only is unenforceable — recorded in notes, not faked).
- Android image HEIC/AVIF encode falls back to JPEG with warning (no HeifWriter yet).
- Filters beyond scale/crop/rotate are validated but no-op in native (Phase-2 GL work).
- `waitForResult` single-waiter contract (Dart calls once); repeated waits get cached payload.
