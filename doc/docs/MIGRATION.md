# Migration Roadmap — shared C++/FFI core

## Current architecture (v0.3.x)

```
Dart (FlutterHandbreak facade / VideoCompressor / ImageCompressor)
  → HandbreakPlatform (plugin_platform_interface)
  → MethodChannel('handbreak') + per-job EventChannel (progress)
  ├─ Android: Kotlin JobManager(state machine) → VideoTranscoder / ImageTranscoder
  │    MediaExtractor → MediaCodec(Surface zero-copy | NV12 CPU) → PTS gate
  │    → audio passthrough/AAC → MediaMuxer → validate → atomic commit
  └─ iOS: Swift JobManager(state machine) → VideoPipeline / ImagePipeline
       AVURLAsset → AVMutableComposition → AVAssetExportSession → validate → commit
```

Policy (dimensions, fps, container fallback, rate control, hardware decision,
audio plan, filter order) already lives **once** in tested Dart
(`EncodePlanResolver` → `ResolvedPlan`); natives are executors.

## Why not rewrite to C++ today

The Kotlin/Swift implementation is behaviorally correct for the shipped feature
set (bounded queues, cancellation, watchdog, state machine, honest reporting).
A C++ core only pays off when platform adapters become *thin*; an uncontrolled
rewrite would add risk without proven benefit. FFI adds C-ABI ownership rules,
per-ABI packaging, and a new failure domain — justified only when duplicated
orchestration is large enough to amortize it.

## Staged plan

1. **Policy core** (Dart, mostly done): expand `EncodePlanResolver` with the
   capability model (per-codec supported/available/hardware/max-dims).
2. **C ABI core** (pure C++, no platform deps):
   `hb_engine_t` / `hb_job_t` opaque handles; job state machine; bounded queues;
   temp/commit; error taxonomy; progress. Unit-tested, sanitizer-clean.
3. **Dart FFI bindings** (ffigen) behind `HandbreakPlatform`; MethodChannel
   retained for capability/probe fallback. No `std::*` or exceptions cross the ABI.
4. **Android adapter** (NDK/MediaCodec async mode) then **Apple adapter**
   (ObjC++ VideoToolbox) — replacing Kotlin/Swift orchestration.
5. **Parity harness**: same fixture matrix on old vs new engine; keep the old
   implementation until parity is proven.

## Trigger criteria (start Stage 2 when any holds)

- Feature demand for GPU filters / HDR / AV1 software encoding
- Measured orchestration overhead in profiling
- Requirement for a desktop/embedded backend sharing the same core

## Ownership rules (for Stage 2+)

- Every allocation crossing the ABI has a matching release function.
- Opaque handles; no C++ types through FFI; exceptions caught at the ABI boundary.
- Engine shutdown cancels and drains all jobs; cancel/dispose idempotent;
  completion exactly once.
