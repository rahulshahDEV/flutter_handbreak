import AVFoundation
import CoreMedia
import UIKit

/// Video transcode executor — runs the Dart-resolved plan via AVFoundation.
///
/// Honesty contract (spec §12): AVAssetExportSession selects its own encoder;
/// we cannot force software on iOS. `usedHardwareAcceleration` therefore
/// reports the *verified* VT hardware-encode capability for the chosen codec,
/// and unenforceable policies are recorded in result details rather than faked.
enum VideoPipeline {

    static func run(job: Job, manager: JobManager, inputPath: String, outputPath: String, options: [String: Any]) {
        let startMs = Int(Date().timeIntervalSince1970 * 1000)
        let fm = FileManager.default

        guard fm.fileExists(atPath: inputPath) else {
            manager.fail(job: job, code: "INVALID_INPUT", message: "Input not found: \(inputPath)")
            return
        }
        if URL(fileURLWithPath: inputPath).standardizedFileURL == URL(fileURLWithPath: outputPath).standardizedFileURL {
            manager.fail(job: job, code: "INVALID_INPUT", message: "Input and output must differ")
            return
        }

        let plan = ResolvedPlan.fromOptions(options)
        var notes = plan?.notes ?? []
        let hwPolicy = options["hardwareAcceleration"] as? String ?? "auto"
        let keepSmaller = options["keepOriginalIfSmaller"] as? Bool ?? false

        do {
            let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath),
                                   options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                manager.fail(job: job, code: "INVALID_INPUT", message: "No video track")
                return
            }
            let naturalSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
            let srcW = abs(Int(naturalSize.width.rounded()))
            let srcH = abs(Int(naturalSize.height.rounded()))
            let srcFps = Double(videoTrack.nominalFrameRate > 0 ? videoTrack.nominalFrameRate : 30)

            let durationMs = Int((CMTimeGetSeconds(asset.duration) * 1000).rounded())
            guard durationMs > 0 else {
                manager.fail(job: job, code: "INVALID_INPUT", message: "Zero-duration or unreadable source")
                return
            }

            // ---- effective config (plan wins; legacy fields as fallback) ----
            let size: ResolutionHelper.Size
            if let p = plan {
                size = ResolutionHelper.Size(width: p.width, height: p.height)
            } else {
                size = ResolutionHelper.calculate(
                    srcWidth: srcW, srcHeight: srcH,
                    maxWidth: options["maxWidth"] as? Int,
                    maxHeight: options["maxHeight"] as? Int,
                    targetWidth: options["targetWidth"] as? Int,
                    targetHeight: options["targetHeight"] as? Int,
                    scale: options["scale"] as? Double)
            }
            let targetFps: Double
            if let p = plan {
                targetFps = p.targetFps
            } else {
                let mf = options["maxFrameRate"] as? Double
                let mode = options["frameRateMode"] as? String ?? "sameAsSource"
                targetFps = (mode != "variable" && mf != nil && mf! < srcFps) ? mf! : srcFps
            }
            let limitFrameRate = plan?.limitFrameRate ?? (targetFps < srcFps - 0.01)

            var container = plan?.container ?? (options["container"] as? String ?? "mp4")
            if container != "mp4" && container != "mov" {
                notes.append("Container \"\(container)\" is not writable by iOS muxers; fell back to \"mp4\".")
                container = "mp4"
            }

            // ---- honest HW decision via real VT probes ----
            let codecId = options["codec"] as? String ?? "h264"
            let codecType: CMVideoCodecType = (codecId == "h265" || codecId == "hevc")
                ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
            let hwEncodeAvailable = HardwareCapabilitiesProvider.vtHardwareEncodeSupported(codecType)

            if hwPolicy == "hardwareOnly" && !hwEncodeAvailable {
                manager.fail(job: job, code: "HARDWARE_UNAVAILABLE",
                             message: "hardwareOnly requested but no hardware encoder for \(codecId) (VT probe failed)")
                return
            }
            var hwNote = plan?.hwFallbackNote
            if !hwEncodeAvailable, hwPolicy != "softwareOnly" {
                hwNote = "Hardware \(codecId) encoder unavailable on this device (VT probe); Apple's software encoder will be used."
                if let n = hwNote { notes.append(n) }
            }
            if hwPolicy == "softwareOnly" {
                notes.append("softwareOnly requested: iOS AVAssetExportSession cannot force Apple's software encoder; recorded honestly instead of enforced.")
            }

            // ---- composition ----
            let composition = AVMutableComposition()
            guard let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
                manager.fail(job: job, code: "ENCODING_ERROR", message: "Failed to create composition track")
                return
            }
            try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration),
                                          of: videoTrack, at: .zero)
            // Orientation applied EXACTLY ONCE (P1-2):
            // - no videoComposition → AVFoundation applies the track transform
            // - videoComposition present → layer instruction owns the transform,
            //   track transform zeroed (avoid double rotation on resize/fps-cap)
            compVideo.preferredTransform = videoTrack.preferredTransform

            // audio per plan: remove → no track; copy/encode → carry source track(s).
            let audioMode = plan?.audioMode ?? audioModeLegacy(options)
            if audioMode != "remove" {
                for at in asset.tracks(withMediaType: .audio) {
                    if let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                                   preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try? compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: at, at: .zero)
                    }
                }
            } else {
                notes.append("Audio removed by request.")
            }

            // ---- video composition for scale / fps cap (preserves orientation transform) ----
            var videoComposition: AVMutableVideoComposition?
            let needsResize = size.width != srcW || size.height != srcH
            if needsResize || limitFrameRate {
                // Single source of truth for orientation: the layer instruction.
                compVideo.preferredTransform = .identity
                let vc = AVMutableVideoComposition()
                vc.renderSize = CGSize(width: size.width, height: size.height)
                // Round fractional FPS (29.97→30, 59.94→60) — frameDuration must be integral (P2-5).
                vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(targetFps.rounded()))))
                let instr = AVMutableVideoCompositionInstruction()
                instr.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
                if needsResize {
                    let sx = CGFloat(size.width) / CGFloat(srcW)
                    let sy = CGFloat(size.height) / CGFloat(srcH)
                    let s = min(sx, sy) // preserve aspect; center letterbox
                    var t = CGAffineTransform(translationX: (CGFloat(size.width) - CGFloat(srcW) * s) / 2,
                                              y: (CGFloat(size.height) - CGFloat(srcH) * s) / 2)
                    t = t.scaledBy(x: s, y: s)
                    layer.setTransform(videoTrack.preferredTransform.concatenating(t), at: .zero)
                } else {
                    layer.setTransform(videoTrack.preferredTransform, at: .zero)
                }
                instr.layerInstructions = [layer]
                vc.instructions = [instr]
                videoComposition = vc
            }

            // ---- export preset from resolved geometry/codec ----
            let preset = exportPreset(for: codecId, height: size.height, targetFps: targetFps)

            guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
                manager.fail(job: job, code: "ENCODING_ERROR", message: "Export session creation failed for preset \(preset)")
                return
            }
            job.setTask(session) // synchronized cancellation hook (audit P1-9)

            // Job-scoped temp file — concurrent jobs can never collide (audit P1-1).
            let tmpPath = outputPath + ".hbtmp.\(job.id)"
            try? fm.removeItem(atPath: tmpPath)
            let tmpUrl = URL(fileURLWithPath: tmpPath)
            session.outputURL = tmpUrl
            session.outputFileType = (container == "mov") ? .mov : .mp4
            session.videoComposition = videoComposition
            session.shouldOptimizeForNetworkUse = true
            session.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

            let ticker = emitProgress(manager, job, session, durationMs, Int(targetFps))

            // 🔴-2: the export wait must be bounded. AVFoundation can in rare
            // cases stall without completing; a watchdog monitors session.progress
            // and cancels + fails the job with TIMEOUT instead of hanging forever.
            let done = DispatchSemaphore(value: 0)
            var stalled = false
            let stallLock = NSLock()
            let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            watchdog.schedule(deadline: .now() + 30, repeating: 5)
            var lastProgress = Double(session.progress)
            watchdog.setEventHandler {
                let p = Double(session.progress)
                if session.status == .exporting && p <= lastProgress {
                    stallLock.lock()
                    if !stalled {
                        stalled = true
                        session.cancelExport()
                        done.signal()
                    }
                    stallLock.unlock()
                }
                lastProgress = p
                if session.status != .exporting {
                    watchdog.cancel()
                }
            }
            watchdog.resume()
            session.exportAsynchronously { done.signal() }
            // Bounded wait: worst case ~30 s after the watchdog cancels.
            done.wait()
            watchdog.cancel()
            ticker.cancel()
            job.setTask(nil)

            stallLock.lock()
            let wasStalled = stalled
            stallLock.unlock()
            if wasStalled {
                try? fm.removeItem(atPath: tmpPath)
                manager.fail(job: job, code: "TIMEOUT", message: "Export stalled: no progress for 30s")
                return
            }

            switch session.status {
            case .completed: break
            case .cancelled:
                try? fm.removeItem(atPath: tmpPath)
                manager.fail(job: job, code: "CANCELLED", message: "Cancelled")
                return
            case .failed:
                try? fm.removeItem(atPath: tmpPath)
                if job.isCancelled {
                    manager.fail(job: job, code: "CANCELLED", message: "Cancelled")
                } else {
                    manager.fail(job: job, code: "ENCODING_ERROR",
                                 message: session.error?.localizedDescription ?? "Export failed")
                }
                return
            default:
                try? fm.removeItem(atPath: tmpPath)
                manager.fail(job: job, code: "ENCODING_ERROR", message: "Unexpected export status \(session.status.rawValue)")
                return
            }

            finish(job: job, manager: manager, inputPath: inputPath, outputPath: outputPath,
                   tmpPath: tmpPath, startMs: startMs, usedHw: hwEncodeAvailable,
                   codecId: codecId, container: container, sourceDurationMs: durationMs,
                   keepSmaller: keepSmaller, notes: &notes)
        } catch let e as ProbeError {
            manager.fail(job: job, code: e.code, message: e.message)
        } catch {
            manager.fail(job: job, code: "ENCODING_ERROR", message: error.localizedDescription)
        }
    }

    static func audioModeLegacy(_ options: [String: Any]) -> String {
        let audio = options["audio"] as? [String: Any]
        return audio?["mode"] as? String == "copy" ? "passthrough" : ((audio?["mode"] as? String) ?? "encode") == "remove" ? "remove" : "transcode"
    }
}
