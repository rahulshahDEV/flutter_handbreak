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
                    // Scale storage-oriented pixels only. Rotation remains
                    // track metadata on the writer, so a portrait source is
                    // not rotated into a landscape render canvas.
                    layer.setTransform(t, at: .zero)
                } else {
                    layer.setTransform(.identity, at: .zero)
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
                // Decode to raw frames (NV12) — the writer encodes from
                // uncompressed input; compressed samples are rejected
                // ("Input buffer must be in an uncompressed format when
                // outputSettings is not nil"). No renderer involved.
                videoOutput = AVAssetReaderTrackOutput(
                    track: videoReadTrack,
                    outputSettings: [
                        (kCVPixelBufferPixelFormatTypeKey as String): kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    ])
            }
            videoOutput.alwaysCopiesSampleData = false
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
            // Rotation as track metadata (source container style) for both
            // plain and composition paths — players rotate for display.
            videoWriterInput.transform = videoTrack.preferredTransform

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

            // ---- concurrent transfers (Apple ReaderWriter pattern) ----
            // AVAssetReader outputs have bounded internal queues. Each output
            // must be consumed on its own serial queue while AVAssetWriter
            // interleaves the inputs itself. A manual video-first or fixed
            // one-video/one-audio loop eventually starves one track and can
            // deadlock the reader at a repeatable percentage.
            var lastVideoPts = 0.0
            var lastVideoProgressAt = Date()
            var videoPumpDone = false
            var videoDoneAt = Date()
            let ptsLock = NSLock()
            let transferLock = NSLock()
            var transferError: ProbeError?
            var stalled = false

            func record(_ sample: CMSampleBuffer) {
                let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                ptsLock.lock()
                lastVideoPts = max(lastVideoPts, t)
                lastVideoProgressAt = Date()
                ptsLock.unlock()
            }
            func readTransferError() -> ProbeError? {
                transferLock.lock(); defer { transferLock.unlock() }
                return transferError
            }
            func readStalled() -> Bool {
                transferLock.lock(); defer { transferLock.unlock() }
                return stalled
            }
            func failTransfer(_ error: ProbeError) {
                transferLock.lock()
                if transferError == nil { transferError = error }
                transferLock.unlock()
                reader.cancelReading()
                writer.cancelWriting()
            }
            func markStalled() {
                transferLock.lock(); stalled = true; transferLock.unlock()
                reader.cancelReading()
                writer.cancelWriting()
            }

            guard writer.startWriting() else {
                manager.fail(job: job, code: "ENCODING_ERROR", message: writer.error?.localizedDescription ?? "Writer start failed")
                return
            }
            writer.startSession(atSourceTime: .zero)
            guard reader.startReading() else {
                writer.cancelWriting()
                manager.fail(job: job, code: "ENCODING_ERROR",
                             message: reader.error?.localizedDescription ?? "Reader start failed")
                return
            }
            job.setTask(writer)

            // Watchdog cancels both sides. In particular, cancelling only the
            // writer does not reliably unblock a reader blocked in
            // copyNextSampleBuffer().
            let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            // Poll frequently so user cancellation is responsive; the stall
            // threshold itself is measured from the last successfully appended
            // video sample, not from the previous watchdog tick.
            watchdog.schedule(deadline: .now() + 1, repeating: 1)
            watchdog.setEventHandler {
                if job.isCancelled {
                    reader.cancelReading(); writer.cancelWriting()
                    return
                }
                ptsLock.lock()
                let vDone = videoPumpDone
                let doneAt = videoDoneAt
                let idleSeconds = Date().timeIntervalSince(lastVideoProgressAt)
                ptsLock.unlock()
                if writer.status == .writing {
                    if !vDone, idleSeconds > 30 {
                        markStalled()
                    } else if vDone, Date().timeIntervalSince(doneAt) > 90 {
                        markStalled()
                    }
                }
                if writer.status != .writing { watchdog.cancel() }
            }
            watchdog.resume()
            let ticker = emitProgress(manager, job, durationMs, Int(targetFps)) {
                ptsLock.lock(); let v = lastVideoPts; ptsLock.unlock()
                return durationMs > 0 ? v / (Double(durationMs) / 1000.0) : 0
            }

            let transferGroup = DispatchGroup()
            func scheduleTransfer(_ output: AVAssetReaderOutput,
                                  _ input: AVAssetWriterInput,
                                  isVideo: Bool,
                                  label: String) {
                transferGroup.enter()
                let queue = DispatchQueue(label: label, qos: .userInitiated)
                var finished = false
                func finishTransfer() {
                    guard !finished else { return }
                    finished = true
                    input.markAsFinished()
                    if isVideo {
                        ptsLock.lock(); videoPumpDone = true; videoDoneAt = Date(); ptsLock.unlock()
                    }
                    transferGroup.leave()
                }
                input.requestMediaDataWhenReady(on: queue) {
                    guard !finished else { return }
                    while input.isReadyForMoreMediaData {
                        if job.isCancelled {
                            failTransfer(ProbeError(code: "CANCELLED", message: "Cancelled"))
                            finishTransfer()
                            return
                        }
                        if readStalled() {
                            finishTransfer()
                            return
                        }
                        if let error = readTransferError() {
                            _ = error
                            finishTransfer()
                            return
                        }
                        if writer.status == .failed {
                            failTransfer(ProbeError(
                                code: "ENCODING_ERROR",
                                message: writer.error?.localizedDescription ?? "Writer failed"))
                            finishTransfer()
                            return
                        }
                        if reader.status == .failed {
                            failTransfer(ProbeError(
                                code: "ENCODING_ERROR",
                                message: reader.error?.localizedDescription ?? "Reader failed"))
                            finishTransfer()
                            return
                        }
                        guard let sample = output.copyNextSampleBuffer() else {
                            if reader.status == .failed {
                                failTransfer(ProbeError(
                                    code: "ENCODING_ERROR",
                                    message: reader.error?.localizedDescription ?? "Reader failed"))
                            }
                            finishTransfer()
                            return
                        }
                        guard input.append(sample) else {
                            failTransfer(ProbeError(
                                code: "ENCODING_ERROR",
                                message: "Writer append failed: \(writer.status.rawValue) \(writer.error?.localizedDescription ?? "")"))
                            finishTransfer()
                            return
                        }
                        if isVideo { record(sample) }
                    }
                    // When the input is temporarily full, return. AVAssetWriter
                    // invokes this same block again when it becomes ready.
                    if job.isCancelled || readStalled() || readTransferError() != nil ||
                        writer.status == .failed || writer.status == .cancelled ||
                        reader.status == .failed || reader.status == .cancelled {
                        finishTransfer()
                    }
                }
            }

            scheduleTransfer(videoOutput, videoWriterInput, isVideo: true,
                             label: "flutter_handbreak.video-transfer")
            for (index, pair) in audioPairs.enumerated() {
                scheduleTransfer(pair.0, pair.1, isVideo: false,
                                 label: "flutter_handbreak.audio-transfer.\(index)")
            }

            // Wait without imposing a limit on normal long encodes. Once a
            // cancellation/failure is observed, allow callbacks a short grace
            // period to leave the group, then fail rather than leak/hang.
            var transfersFinished = false
            var abortDeadline: Date?
            while !transfersFinished {
                if transferGroup.wait(timeout: .now() + .milliseconds(500)) == .success {
                    transfersFinished = true
                    break
                }
                if job.isCancelled || readStalled() || readTransferError() != nil || writer.status == .failed {
                    reader.cancelReading(); writer.cancelWriting()
                    if abortDeadline == nil { abortDeadline = Date().addingTimeInterval(5) }
                }
                if let deadline = abortDeadline, Date() >= deadline { break }
            }

            if !transfersFinished {
                watchdog.cancel(); ticker.cancel(); job.setTask(nil)
                try? fm.removeItem(atPath: tmpPath)
                if readStalled() {
                    manager.fail(job: job, code: "TIMEOUT", message: "Encode stalled: no progress for 30s")
                } else if job.isCancelled {
                    manager.fail(job: job, code: "CANCELLED", message: "Cancelled")
                } else {
                    manager.fail(job: job, code: "ENCODING_ERROR",
                                 message: readTransferError()?.message ?? writer.error?.localizedDescription ?? "Media transfer did not finish")
                }
                return
            }

            if let error = readTransferError() {
                watchdog.cancel(); ticker.cancel(); job.setTask(nil)
                try? fm.removeItem(atPath: tmpPath)
                manager.fail(job: job, code: error.code, message: error.message)
                return
            }
            if readStalled() {
                watchdog.cancel(); ticker.cancel(); job.setTask(nil)
                try? fm.removeItem(atPath: tmpPath)
                manager.fail(job: job, code: "TIMEOUT", message: "Encode stalled: no progress for 30s")
                return
            }
            if job.isCancelled {
                watchdog.cancel(); ticker.cancel(); job.setTask(nil)
                try? fm.removeItem(atPath: tmpPath)
                manager.fail(job: job, code: "CANCELLED", message: "Cancelled")
                return
            }

            let finishSemaphore = DispatchSemaphore(value: 0)
            writer.finishWriting { finishSemaphore.signal() }
            if finishSemaphore.wait(timeout: .now() + 120) == .timedOut {
                markStalled()
            }
            watchdog.cancel()
            ticker.cancel()
            job.setTask(nil)

            if readStalled() {
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
