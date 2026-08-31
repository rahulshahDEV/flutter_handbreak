import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Image transcode executor — probe → decode → EXIF-orient → resize → encode → validate.
///
/// Fixes audit P0-6: EXIF orientation is actually applied via a draw transform
/// (previously computed and ignored). Output dimensions are oriented dimensions.
enum ImagePipeline {

    static func run(job: Job, manager: JobManager, inputPath: String, outputPath: String, options: [String: Any]) {
        let startMs = Int(Date().timeIntervalSince1970 * 1000)
        let fm = FileManager.default

        guard fm.fileExists(atPath: inputPath) else {
            manager.fail(job: job, code: "INVALID_INPUT", message: "Input not found")
            return
        }
        if URL(fileURLWithPath: inputPath).standardizedFileURL == URL(fileURLWithPath: outputPath).standardizedFileURL {
            manager.fail(job: job, code: "INVALID_INPUT", message: "Input and output must differ")
            return
        }

        // Audit P1-8: use a URL-based source — ImageIO decodes lazily and we
        // NEVER load the entire file into memory (Data(contentsOf:) OOM risk
        // on huge images).
        let sourceURL = URL(fileURLWithPath: inputPath)
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            manager.fail(job: job, code: "INVALID_INPUT", message: "Not a decodable image")
            return
        }

        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]

        let quality = options["quality"] as? Int ?? 82
        let maxW = options["maxWidth"] as? Int
        let maxH = options["maxHeight"] as? Int
        var format = (options["format"] as? String ?? "auto").lowercased()
        let preserveExif = options["preserveExif"] as? Bool ?? false
        let keepSmaller = options["keepOriginalIfSmaller"] as? Bool ?? true

        // ---- oriented dimensions (EXIF 5-8 swap w/h) ----
        guard let rawW = props[kCGImagePropertyPixelWidth] as? Int,
              let rawH = props[kCGImagePropertyPixelHeight] as? Int, rawW > 0, rawH > 0 else {
            manager.fail(job: job, code: "INVALID_INPUT", message: "Image has no pixel dimensions")
            return
        }
        let orientationRaw = props[kCGImagePropertyOrientation] as? Int ?? 1
        let swapsDimensions = (5...8).contains(orientationRaw)
        let orientedW = swapsDimensions ? rawH : rawW
        let orientedH = swapsDimensions ? rawW : rawH

        // P2-2 decompression-bomb guard: without explicit target dimensions a
        // gigantic source would decode at full resolution and likely OOM.
        let totalPixels = Int64(orientedW) * Int64(orientedH)
        if maxW == nil && maxH == nil && totalPixels > 100_000_000 {
            manager.fail(job: job, code: "INVALID_INPUT",
                         message: "Image too large to decode safely (\(orientedW)x\(orientedH)); pass maxWidth/maxHeight to downsample")
            return
        }

        // ---- decode upright at needed size via Apple's transform-aware thumbnail ----
        // (replaces hand-written affine EXIF math — audit P0-6; Apple applies
        //  orientation correctly for all 8 cases including mirrored variants)
        let maxPixelSize: Int = max(maxW ?? orientedW, maxH ?? orientedH)
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, max(orientedW, orientedH)),
        ]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
            manager.fail(job: job, code: "ENCODING_ERROR", message: "Failed to decode image")
            return
        }

        let hasAlpha = hasAlphaChannel(upright)

        emit(manager, job, 0.25, stage: "decode")
        if job.isCancelled { manager.fail(job: job, code: "CANCELLED", message: "Cancelled"); return }

        // ---- resize preserving aspect from oriented dims (never implicit upscale) ----
        let target = ResolutionHelper.calculate(srcWidth: upright.width, srcHeight: upright.height,
                                                maxWidth: maxW, maxHeight: maxH,
                                                targetWidth: nil, targetHeight: nil, scale: nil)

        emit(manager, job, 0.5, stage: "filter")

        if job.isCancelled { manager.fail(job: job, code: "CANCELLED", message: "Cancelled"); return }

        guard let rendered = renderScaled(upright, target.width, target.height, hasAlpha) else {
            manager.fail(job: job, code: "ENCODING_ERROR", message: "Failed to allocate render context")
            return
        }

        if format == "auto" || format.isEmpty {
            // Preserve HEIC efficiency: HEIC source at same resolution re-encoded as JPEG
            // at quality 82 is often LARGER than the original (HEIC ~50% smaller than JPEG).
            // Keep HEIC when the source is HEIC and the device can write it.
            let sourceUTI = CGImageSourceGetType(source) as String?
            if sourceUTI == "public.heic" && !hasAlpha && destinationTypeAvailable("public.heic") {
                format = "heic"
            } else {
                format = hasAlpha ? "png" : "jpeg"
            }
        }
        // Honesty (audit P1-7 parity): if the requested format cannot be written
        // by this device, fall back to JPEG AND report it with a warning — never
        // claim a codec that wasn't actually produced.
        var warnings: [String] = []
        var uti = utiFor(format)
        if uti == nil || !destinationTypeAvailable(uti!) {
            if uti != nil { warnings.append("\(format) encoding unavailable on this device; wrote JPEG instead.") }
            format = "jpeg"
            uti = "public.jpeg"
        }
        guard let uti else {
            manager.fail(job: job, code: "UNSUPPORTED_FORMAT", message: "Unsupported image format: \(format)")
            return
        }

        // destination path extension follows resolved format
        var finalOut = outputPath
        let wantExt = fileExtFor(format)
        if (finalOut as NSString).pathExtension.lowercased() != wantExt {
            finalOut = ((finalOut as NSString).deletingPathExtension as NSString)
                .appendingPathExtension(wantExt) ?? finalOut + "." + wantExt
        }
        try? fm.createDirectory(atPath: (finalOut as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)

        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: finalOut) as CFURL, uti as CFString, 1, nil) else {
            manager.fail(job: job, code: "OUTPUT_CREATION_FAILED", message: "Cannot create \(uti) destination")
            return
        }

        // Lossy quality applies to jpeg/webp/heic; png is lossless (no knob).
        var encOpts: [CFString: Any] = [:]
        switch uti {
        case "public.jpeg", "public.heic", "org.webmproject.webp":
            encOpts[kCGImageDestinationLossyCompressionQuality] = Double(quality) / 100.0
        default:
            break
        }
        if preserveExif, let exifSrc = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let gpsSrc = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            encOpts[kCGImagePropertyExifDictionary] = exifSrc
            encOpts[kCGImagePropertyGPSDictionary] = gpsSrc
        }
        // orientation is baked into pixels now — always write normal orientation
        encOpts[kCGImagePropertyOrientation] = CGImagePropertyOrientation.up.rawValue

        CGImageDestinationAddImage(dest, rendered, encOpts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            manager.fail(job: job, code: "ENCODING_ERROR", message: "Image finalize failed")
            return
        }

        emit(manager, job, 0.9, stage: "validate")

        if job.isCancelled { manager.fail(job: job, code: "CANCELLED", message: "Cancelled"); return }

        let inSize = ((try? fm.attributesOfItem(atPath: inputPath))? [.size] as? NSNumber)?.int64Value ?? 0
        guard let outAttrs = try? fm.attributesOfItem(atPath: finalOut),
              let outSize = (outAttrs[.size] as? NSNumber)?.int64Value, outSize > 0 else {
            manager.fail(job: job, code: "ENCODING_ERROR", message: "Encoder produced empty output")
            return
        }

        if keepSmaller && outSize >= inSize && inSize > 0 {
            try? fm.removeItem(atPath: finalOut)
            var r = VideoPipeline.baseResult(inputPath: inputPath, outputPath: inputPath,
                                             inSize: inSize, outSize: inSize, startMs: startMs,
                                             usedHw: false, codecId: format, container: format,
                                             keptOriginal: true)
            warnings.append("Output would be larger than source (\(format)); original kept.")
            r["qualityWarning"] = warnings.joined(separator: " ")
            manager.complete(job: job, result: r)
            return
        }

        let saved = max(0, inSize - outSize)
        var r = VideoPipeline.baseResult(inputPath: inputPath, outputPath: finalOut,
                                         inSize: inSize, outSize: outSize, startMs: startMs,
                                         usedHw: false, codecId: format, container: format,
                                         keptOriginal: false)
        r["compressionRatio"] = Double(inSize) / Double(outSize)
        r["compressionPercentage"] = inSize > 0 ? Double(saved) / Double(inSize) * 100 : 0.0
        r["qualityWarning"] = warnings.isEmpty ? NSNull() : warnings.joined(separator: " ")
        manager.complete(job: job, result: r)
    }

    /// Ask ImageIO whether this device can actually write the given UTI
    /// (audit P1-7: never advertise formats the device cannot encode).
    private static func destinationTypeAvailable(_ uti: String) -> Bool {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains(uti)
    }

    private static func emit(_ m: JobManager, _ j: Job, _ p: Double, stage: String) {
        m.emitProgress(j, [
            "progress": p, "processedDurationMs": Int(p * 1000), "totalDurationMs": 1000,
            "encodedFrames": p >= 1 ? 1 : 0, "totalFrames": 1, "currentFps": 0.0, "stage": stage,
        ])
    }

    static func hasAlphaChannel(_ cg: CGImage) -> Bool {
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    static func renderScaled(_ cg: CGImage, _ w: Int, _ h: Int, _ alpha: Bool) -> CGImage? {
        if w == cg.width && h == cg.height { return cg }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bi = (alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: bi) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func utiFor(_ format: String) -> String? {
        switch format {
        case "jpeg", "jpg": return "public.jpeg"
        case "png": return "public.png"
        case "webp": return "org.webmproject.webp"
        case "heic", "heif": return "public.heic"
        case "avif": return "public.avif"
        default: return nil
        }
    }

    static func fileExtFor(_ format: String) -> String {
        switch format {
        case "png": return "png"
        case "webp": return "webp"
        case "heic", "heif": return "heic"
        case "avif": return "avif"
        default: return "jpg"
        }
    }
}
