import AVFoundation
import CoreMedia
import UIKit
import VideoToolbox

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
            let rawSize = videoTrack.naturalSize
            let srcW = abs(Int(rawSize.width.rounded()))
            let srcH = abs(Int(rawSize.height.rounded()))
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

            // ---- composition: ONLY for resize / fps-cap ----
            // Rotation is carried as TRACK METADATA (writerInput.transform),
            // mirroring the source container and the Android orientation hint —
            // NO renderer in the common path. AVAssetReaderVideoCompositionOutput
            // (the pixel renderer) is the known AVFoundation stall point; it is
            // used only when actual pixel work (resize/fps) is requested.
            let audioMode = plan?.audioMode ?? audioModeLegacy(options)
            let needsResize = size.width != srcW || size.height != srcH
            let needsComposition = needsResize || limitFrameRate

            let readerAsset: AVAsset
            var videoReadTrack: AVAssetTrack
            var audioReadTracks: [AVAssetTrack]
            var videoComposition: AVMutableVideoComposition?
            if needsComposition {
                let composition = AVMutableComposition()
                guard let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                                   preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    manager.fail(job: job, code: "ENCODING_ERROR", message: "Failed to create composition track")
                    return
                }
                try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration),
                                              of: videoTrack, at: .zero)
                // Single source of truth for orientation: the layer instruction.
                compVideo.preferredTransform = .identity
                // audio per plan: remove → no track; copy/encode → carry source track(s).
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
                readerAsset = composition
                videoReadTrack = compVideo
                audioReadTracks = composition.tracks(withMediaType: .audio)
            } else {
                readerAsset = asset
                videoReadTrack = videoTrack
                audioReadTracks = asset.tracks(withMediaType: .audio)
            }

            // ---- HandBrake-style explicit encode: AVAssetReader + AVAssetWriter ----
            // AVAssetExportSession presets cannot honor the plan's bitrate/quality
            // (they re-encode at Apple's fixed ladders → output larger than the
            // source). The writer pipeline sets explicit compression properties,
            // mirroring libx264's param pass — the ONLY way to guarantee that
            // same-resolution compression actually produces a smaller file.

            // Job-scoped temp file — concurrent jobs can never collide (audit P1-1).
            let tmpPath = outputPath + ".hbtmp.\(job.id)"
            try? fm.removeItem(atPath: tmpPath)
            let tmpUrl = URL(fileURLWithPath: tmpPath)

            guard let reader = try? AVAssetReader(asset: readerAsset) else {
                manager.fail(job: job, code: "ENCODING_ERROR", message: "Failed to create AVAssetReader")
                return
            }
            reader.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

            let videoOutput: AVAssetReaderOutput
            if needsComposition {
                // videoComposition renders scale/fps into plan dims.
                let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: [videoReadTrack], videoSettings: nil)
                vOut.videoComposition = videoComposition
                videoOutput = vOut
            } else {
                // Plain track read — compressed samples straight to the writer.
                videoOutput = AVAssetReaderTrackOutput(track: videoReadTrack, outputSettings: nil)
            }
            guard reader.canAdd(videoOutput) else {
                manager.fail(job: job, code: "ENCODING_ERROR", message: "Reader rejected video output")
                return
            }
            reader.add(videoOutput)

            // Explicit compression properties from the plan (HandBrake param pass).
            let targetBitrateKbps = resolveBitrateKbps(
                plan: plan, options: options, codecId: codecId,
                w: size.width,
                h: size.height,
                fps: targetFps)
            var compProps: [String: Any] = [
                AVVideoAverageBitRateKey: targetBitrateKbps * 1000,
                AVVideoMaxKeyFrameIntervalKey: max(1, Int(targetFps.rounded()) * 2),
                AVVideoExpectedSourceFrameRateKey: targetFps,
            ]
            compProps[AVVideoProfileLevelKey] = (codecId == "h265" || codecId == "hevc")
                ? (kVTProfileLevel_HEVC_Main_AutoLevel as String) : AVVideoProfileLevelH264HighAutoLevel
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: (codecId == "h265" || codecId == "hevc")
                    ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoCompressionPropertiesKey: compProps,
            ]
            let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoWriterInput.expectsMediaDataInRealTime = false
            // Rotation as track metadata (source container style) when the
            // renderer is not in use — players rotate for display.
            if !needsComposition {
                videoWriterInput.transform = videoTrack.preferredTransform
            }

            let writer = try AVAssetWriter(outputURL: tmpUrl, fileType: (container == "mov") ? .mov : .mp4)
            guard writer.canAdd(videoWriterInput) else {
                manager.fail(job: job, code: "ENCODING_ERROR", message: "Writer rejected video input")
                return
            }
            writer.add(videoWriterInput)

            // ---- audio: passthrough (compressed copy) or AAC transcode ----
            var audioPairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
            if audioMode != "remove" {
                for at in audioReadTracks {
                    let audioInput: AVAssetWriterInput
                    let audioReaderOutput: AVAssetReaderOutput
                    if audioMode == "passthrough" {
                        audioReaderOutput = AVAssetReaderTrackOutput(track: at, outputSettings: nil)
                        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
                    } else {
                        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(at.formatDescriptions.first as! CMAudioFormatDescription)
                        let srcRate = Int(asbd?.pointee.mSampleRate ?? 48000)
                        let srcCh = min(Int(asbd?.pointee.mChannelsPerFrame ?? 2), 2)
                        let aacSettings: [String: Any] = [
                            AVFormatIDKey: kAudioFormatMPEG4AAC,
                            AVSampleRateKey: srcRate,
                            AVNumberOfChannelsKey: srcCh,
                            AVEncoderBitRateKey: (plan?.audioBitrateKbps ?? 128) * 1000,
                        ]
                        audioReaderOutput = AVAssetReaderTrackOutput(
                            track: at, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
                    }
                    audioReaderOutput.alwaysCopiesSampleData = false
                    audioInput.expectsMediaDataInRealTime = false
                    if reader.canAdd(audioReaderOutput) && writer.canAdd(audioInput) {
                        reader.add(audioReaderOutput)
                        writer.add(audioInput)
                        audioPairs.append((audioReaderOutput, audioInput))
                    } else {
                        notes.append("Audio track skipped: reader/writer rejected it.")
                    }
                }
            }

            // ---- pump ----
            var lastVideoPts = 0.0
            var videoPumpDone = false
            var videoDoneAt = Date()
            let ptsLock = NSLock()
            func record(_ sample: CMSampleBuffer) {
                let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                ptsLock.lock(); lastVideoPts = max(lastVideoPts, t); ptsLock.unlock()
            }
            // Fail-fast pump: bounded backpressure with writer/reader status
            // checks — a dead codec must never hang the job (spins ≤ 30 s,
            // watchdog cancels BOTH writer and reader to unblock the pump).
            func pump(_ out: AVAssetReaderOutput, into input: AVAssetWriterInput, trackPts: Bool) throws {
                var spins = 0
                while let sb = out.copyNextSampleBuffer() {
                    if job.isCancelled { throw ProbeError(code: "CANCELLED", message: "Cancelled") }
                    spins = 0
                    while !input.isReadyForMoreMediaData {
                        if job.isCancelled { throw ProbeError(code: "CANCELLED", message: "Cancelled") }
                        if writer.status == .failed {
                            throw ProbeError(code: "ENCODING_ERROR",
                                             message: writer.error?.localizedDescription ?? "Writer failed")
                        }
                        if writer.status == .cancelled || reader.status == .failed {
                            throw ProbeError(code: "TIMEOUT", message: "Encode stalled: no progress for 30s")
                        }
                        spins += 1
                        if spins > 300_000 { throw ProbeError(code: "TIMEOUT", message: "Writer input stalled (30s)") }
                        usleep(100)
                    }
                    if trackPts { record(sb) }
                    guard input.append(sb) else {
                        throw ProbeError(code: "ENCODING_ERROR",
                                         message: "Writer append failed: \(writer.status.rawValue) \(writer.error?.localizedDescription ?? "")")
                    }
                }
                input.markAsFinished()
                if trackPts {
                    ptsLock.lock(); videoPumpDone = true; videoDoneAt = Date(); ptsLock.unlock()
                }
            }

            guard writer.startWriting() else {
                manager.fail(job: job, code: "ENCODING_ERROR", message: writer.error?.localizedDescription ?? "Writer start failed")
                return
            }
            writer.startSession(atSourceTime: .zero)
            reader.startReading()

            job.setTask(writer)

            // Watchdog — two phases:
            //  video phase: no PTS progress for 30 s ⇒ stall (codec hung).
            //  audio/finalize phase: video done, writing must finish within 90 s.
            // On stall cancel BOTH writer and reader so a blocked
            // copyNextSampleBuffer() unblocks and the pump throws fast.
            var stalled = false
            let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            watchdog.schedule(deadline: .now() + 30, repeating: 5)
            var lastPts = 0.0
            watchdog.setEventHandler {
                if job.isCancelled { return }
                ptsLock.lock()
                let p = lastVideoPts
                let vDone = videoPumpDone
                let doneAt = videoDoneAt
                ptsLock.unlock()
                if writer.status == .writing {
                    if !vDone {
                        if p <= lastPts {
                            stalled = true
                            writer.cancelWriting()
                            reader.cancelReading()
                        }
                    } else if Date().timeIntervalSince(doneAt) > 90 {
                        stalled = true
                        writer.cancelWriting()
                        reader.cancelReading()
                    }
                }
                lastPts = p
                if writer.status != .writing { watchdog.cancel() }
            }
            watchdog.resume()
            let ticker = emitProgress(manager, job, durationMs, Int(targetFps)) {
                ptsLock.lock(); let v = lastVideoPts; ptsLock.unlock()
                return durationMs > 0 ? v / (Double(durationMs) / 1000.0) : 0
            }

            do {
                try pump(videoOutput, into: videoWriterInput, trackPts: true)
                for (rOut, wIn) in audioPairs { try pump(rOut, into: wIn, trackPts: false) }
                if reader.status == .reading {
                    if job.isCancelled { reader.cancelReading() }
                }
                writer.finishWriting {
                    ptsLock.lock(); lastVideoPts = max(lastVideoPts, Double(durationMs) / 1000.0)
                    ptsLock.unlock()
                }
                var waitMs = 0
                while writer.status == .writing {
                    if job.isCancelled {
                        writer.cancelWriting()
                        break
                    }
                    if stalled { break }
                    waitMs += 50
                    if waitMs > 120_000 { // final safety valve
                        stalled = true
                        writer.cancelWriting()
                        reader.cancelReading()
                        break
                    }
                    usleep(50_000)
                }
            } catch let e as ProbeError {
                try? fm.removeItem(atPath: tmpPath)
                manager.fail(job: job, code: stalled ? "TIMEOUT" : e.code,
                             message: stalled ? "Encode stalled: no progress for 30s" : e.message)
                watchdog.cancel(); ticker.cancel(); job.setTask(nil)
                return
            } catch {
                try? fm.removeItem(atPath: tmpPath)
                manager.fail(job: job, code: "ENCODING_ERROR", message: error.localizedDescription)
                watchdog.cancel(); ticker.cancel(); job.setTask(nil)
                return
            }
            watchdog.cancel()
            ticker.cancel()
            job.setTask(nil)

            if stalled {
                try? fm.removeItem(atPath: tmpPath)
                manager.fail(job: job, code: "TIMEOUT", message: "Encode stalled: no progress for 30s")
                return
            }
            if job.isCancelled {
                try? fm.removeItem(atPath: tmpPath)
                manager.fail(job: job, code: "CANCELLED", message: "Cancelled")
                return
            }
            if writer.status != .completed {
                try? fm.removeItem(atPath: tmpPath)
                manager.fail(job: job, code: "ENCODING_ERROR",
                             message: writer.error?.localizedDescription ?? "Export failed (status \(writer.status.rawValue))")
                return
            }
            if reader.status == .failed {
                try? fm.removeItem(atPath: tmpPath)
                manager.fail(job: job, code: "ENCODING_ERROR",
                             message: reader.error?.localizedDescription ?? "Reader failed")
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
