import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension VideoPipeline {

    static func exportPreset(for codecId: String, height: Int, targetFps: Double) -> String {
        let hevcRequested = (codecId == "h265" || codecId == "hevc")
        if hevcRequested {
            if #available(iOS 11.0, *) { return AVAssetExportPresetHEVCHighestQuality }
            return AVAssetExportPresetHighestQuality
        }
        switch height {
        case 2160...:
            if #available(iOS 9.0, *) { return AVAssetExportPreset3840x2160 }
            return AVAssetExportPresetHighestQuality
        case 1080...: return AVAssetExportPreset1920x1080
        case 720...: return AVAssetExportPreset1280x720
        default: return AVAssetExportPreset640x480
        }
    }

    /// Progress ticker — real session.progress, clamped like sync.c.
    /// Returns the timer so the pipeline can cancel it deterministically on completion.
    static func emitProgress(_ manager: JobManager, _ job: Job, _ session: AVAssetExportSession,
                             _ durationMs: Int, _ targetFps: Int) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(120))
        let estFrames = Int((Double(durationMs) / 1000.0) * Double(max(1, targetFps)))
        timer.setEventHandler { [weak session] in
            guard let session = session else { timer.cancel(); return }
            if job.isCancelled {
                session.cancelExport()
                timer.cancel()
                return
            }
            let p = min(max(Double(session.progress), 0), 1)
            manager.emitProgress(job, [
                "progress": p,
                "processedDurationMs": Int(Double(durationMs) * p),
                "totalDurationMs": durationMs,
                "encodedFrames": Int(Double(estFrames) * p),
                "totalFrames": estFrames,
                "currentFps": Double(targetFps) * p,
                "stage": "encode",
                "state": job.state.rawValue,
            ])
        }
        timer.resume()
        return timer
    }

    static func finish(job: Job, manager: JobManager, inputPath: String, outputPath: String,
                       tmpPath: String, startMs: Int, usedHw: Bool, codecId: String, container: String,
                       sourceDurationMs: Int, keepSmaller: Bool, notes: inout [String]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: tmpPath),
              let attrs = try? fm.attributesOfItem(atPath: tmpPath),
              let outSize = (attrs[.size] as? NSNumber)?.int64Value,
              outSize > 0 else {
            try? fm.removeItem(atPath: tmpPath)
            manager.fail(job: job, code: "ENCODING_ERROR", message: "Encoder produced no output")
            return
        }

        let inSize = ((try? fm.attributesOfItem(atPath: inputPath))?[.size] as? NSNumber)?.int64Value ?? outSize

        if keepSmaller && outSize >= inSize {
            try? fm.removeItem(atPath: tmpPath)
            notes.append("Output would be larger than source; original kept.")
            var r = baseResult(inputPath: inputPath, outputPath: inputPath, inSize: inSize,
                               outSize: inSize, startMs: startMs, usedHw: usedHw,
                               codecId: codecId, container: container, keptOriginal: true)
            r["qualityWarning"] = notes.isEmpty ? NSNull() : notes.joined(separator: " ")
            manager.complete(job: job, result: r)
            return
        }

        // Audit P1-11: validate the temp output BEFORE committing it (parity with
        // Android). Duration must be within tolerance of the source duration.
        if sourceDurationMs > 500,
           let probeTmp = try? MediaProbe.probe(path: tmpPath),
           let outDur = probeTmp["durationMs"] as? Int {
            let tolerance = max(1500, sourceDurationMs / 4)
            if abs(outDur - sourceDurationMs) > tolerance {
                try? fm.removeItem(atPath: tmpPath)
                manager.fail(job: job, code: "ENCODING_ERROR",
                             message: "Duration mismatch: expected ~\(sourceDurationMs)ms got \(outDur)ms")
                return
            }
        }

        try? fm.removeItem(atPath: outputPath)
        do {
            try fm.moveItem(atPath: tmpPath, toPath: outputPath)
        } catch {
            try? fm.copyItem(atPath: tmpPath, toPath: outputPath)
            try? fm.removeItem(atPath: tmpPath)
        }

        // validation re-probe before reporting success
        guard let probeOut = try? MediaProbe.probe(path: outputPath) else {
            manager.fail(job: job, code: "ENCODING_ERROR", message: "Post-encode probe failed — output unreadable")
            return
        }
        let finalSize = ((try? fm.attributesOfItem(atPath: outputPath))?[.size] as? NSNumber)?.int64Value ?? outSize
        let saved = max(0, inSize - finalSize)
        if saved > 0 && inSize > 0 && (Double(saved) / Double(inSize)) < 0.05 {
            if let srcBr = (try? MediaProbe.probe(path: inputPath))?["overallBitrate"] as? Int,
               srcBr >= 1, srcBr < 1_500_000 {
                notes.append("Source appears already heavily compressed; recompression saved only \(String(format: "%.1f", Double(saved) / Double(inSize) * 100))%.")
            }
        }

        var r = baseResult(inputPath: inputPath, outputPath: outputPath, inSize: inSize,
                           outSize: finalSize, startMs: startMs, usedHw: usedHw,
                           codecId: codecId, container: container, keptOriginal: false)
        r["outputMediaInfo"] = probeOut
        r["qualityWarning"] = notes.isEmpty ? NSNull() : notes.joined(separator: " ")
        manager.complete(job: job, result: r)
    }

    static func baseResult(inputPath: String, outputPath: String, inSize: Int64, outSize: Int64,
                           startMs: Int, usedHw: Bool, codecId: String, container: String,
                           keptOriginal: Bool) -> [String: Any] {
        let saved = max(0, inSize - outSize)
        return [
            "inputPath": inputPath,
            "outputPath": outputPath,
            "originalSizeBytes": Int(inSize),
            "outputSizeBytes": Int(outSize),
            "savedBytes": Int(saved),
            "compressionRatio": outSize > 0 ? Double(inSize) / Double(outSize) : 1.0,
            "compressionPercentage": inSize > 0 ? Double(saved) / Double(inSize) * 100 : 0.0,
            "durationMs": Int(Date().timeIntervalSince1970 * 1000) - startMs,
            "usedHardwareAcceleration": usedHw,
            "codec": codecId,
            "container": container,
            "wasKeptOriginal": keptOriginal,
        ]
    }
}
