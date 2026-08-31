import AVFoundation
import CoreMedia
import ImageIO

/// Robust source analysis (scan.c analogue). No force-casts — malformed
/// containers degrade gracefully instead of crashing.
enum MediaProbe {

    static func probe(path: String) throws -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw ProbeError(code: "INVALID_INPUT", message: "File not found: \(path)")
        }
        let attrs = try? fm.attributesOfItem(atPath: path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        // Try as A/V media first.
        if let streams = avStreams(path: path, fileSize: fileSize) {
            return streams
        }

        // Fall back to still-image probe.
        if let imageProbe = imageProbe(path: path, fileSize: fileSize) {
            return imageProbe
        }

        throw ProbeError(code: "UNSUPPORTED_FORMAT", message: "No decodable video, audio, or image tracks")
    }

    // -------------------------------------------------------------- A/V

    private static func avStreams(path: String, fileSize: Int64) -> [String: Any]? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let durationMs = Int((CMTimeGetSeconds(asset.duration) * 1000).rounded())
        guard durationMs > 0 else { return nil }
        let videoTracks = asset.tracks(withMediaType: .video)
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { return nil }

        var videoStreams: [[String: Any]] = []
        for (idx, track) in videoTracks.enumerated() {
            let rawSize = track.naturalSize
            let rawW = abs(Int(rawSize.width.rounded()))
            let rawH = abs(Int(rawSize.height.rounded()))
            let size = rawSize.applying(track.preferredTransform)
            let w = abs(Int(size.width.rounded()))
            let h = abs(Int(size.height.rounded()))
            let fps = Double(track.nominalFrameRate)

            // rotation from affine transform
            let t = track.preferredTransform
            let angleDeg = atan2(t.b, t.a) * 180.0 / .pi
            var rotation = Int(angleDeg.rounded().truncatingRemainder(dividingBy: 360))
            if rotation < 0 { rotation += 360 }
            if rotation != 0 && rotation != 90 && rotation != 180 && rotation != 270 { rotation = 0 }

            var codec = "unknown"
            if let descs = track.formatDescriptions as? [CMFormatDescription], let d = descs.first {
                codec = codecName(CMFormatDescriptionGetMediaSubType(d))
            }
            let bitRate = Int(track.estimatedDataRate)
            let isHdr = hdrInfo(track: track)

            videoStreams.append([
                "index": idx,
                "codec": codec,
                "codecString": codec,
                "width": w,
                "height": h,
                // STORAGE (decoded) dims — the decoder outputs these; encoders
                // must be sized from them. width/height are display-corrected.
                "rawWidth": rawW,
                "rawHeight": rawH,
                "rotation": rotation,
                "frameRate": fps,
                "averageFrameRate": fps,
                "isVariableFrameRate": abs(fps - Double(track.nominalFrameRate)) > 100, // nominal vs decoded variance unknown; conservative false
                "durationMs": durationMs,
                "bitRate": bitRate,
                "pixelFormat": "yuv420p",
                "colorPrimaries": isHdr.primaries,
                "colorTransfer": isHdr.transfer,
                "colorMatrix": "unknown",
                "colorRange": "unknown",
                "bitDepth": isHdr.bitDepth,
                "isHdr": isHdr.isHdr,
                "hdrType": NSNull(),
                "displayAspectRatio": h != 0 ? Double(w) / Double(h) : 0.0,
                "sampleAspectRatio": 1.0,
            ])
        }

        var audioStreams: [[String: Any]] = []
        for (idx, track) in audioTracks.enumerated() {
            var codec = "aac"
            var sampleRate = 44100
            var channels = 2
            if let descs = track.formatDescriptions as? [CMFormatDescription], let d = descs.first {
                codec = codecName(CMFormatDescriptionGetMediaSubType(d))
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d) {
                    sampleRate = Int(asbd.pointee.mSampleRate)
                    channels = Int(asbd.pointee.mChannelsPerFrame)
                }
            }
            audioStreams.append([
                "index": idx,
                "codec": codec,
                "codecString": codec,
                "sampleRate": sampleRate,
                "channelCount": channels,
                "bitRate": Int(track.estimatedDataRate),
                "language": NSNull(),
                "channelLayout": channels == 1 ? "mono" : (channels == 2 ? "stereo" : "\(channels)ch"),
            ])
        }

        let overallBitrate = durationMs > 0 ? Int((Double(fileSize * 8 * 1000) / Double(durationMs)).rounded()) : 0
        return [
            "path": path,
            "container": URL(fileURLWithPath: path).pathExtension.lowercased(),
            "durationMs": durationMs,
            "fileSizeBytes": Int(fileSize),
            "overallBitrate": overallBitrate,
            "videoStreams": videoStreams,
            "audioStreams": audioStreams,
            "metadata": [:],
            "estimatedSourceBitrate": overallBitrate,
            "hasBFrames": false,
        ]
    }

    private struct TrackColor {
        let isHdr: Bool
        let primaries: String
        let transfer: String
        let bitDepth: Int
    }

    private static func hdrInfo(track: AVAssetTrack) -> TrackColor {
        guard let descs = track.formatDescriptions as? [CMFormatDescription], let d = descs.first else {
            return TrackColor(isHdr: false, primaries: "unknown", transfer: "unknown", bitDepth: 8)
        }
        let prim = CMFormatDescriptionGetExtension(d, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String ?? "unknown"
        let xfer = CMFormatDescriptionGetExtension(d, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String ?? "unknown"
        let depthExt = CMFormatDescriptionGetExtension(d, extensionKey: "Depth" as CFString) as? NSNumber
        let depth = depthExt?.intValue ?? 8
        let hdr = prim.contains("2020") || prim.contains("P3") || xfer.contains("PQ") || xfer.contains("HLG") || xfer.contains("SMPTE") || depth > 8
        return TrackColor(isHdr: hdr, primaries: prim, transfer: xfer, bitDepth: depth)
    }

    private static func codecName(_ code: FourCharCode) -> String {
        switch code {
        case kCMVideoCodecType_H264: return "h264"
        case kCMVideoCodecType_HEVC: return "h265"
        case 0x61763031 /* 'av01' */ : return "av1"
        case 0x76703039 /* 'vp09' */ : return "vp9"
        case 0x61632D33 /* 'ac-3' */ : return "ac3"
        case 0x65632D33 /* 'ec-3' */ : return "eac3"
        case 0x6F707573 /* 'opus' */ : return "opus"
        case 0x616C6163 /* 'alac' */ : return "alac"
        default: break
        }
        // FourCC → string fallback for mp4a etc.
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        let s = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "unknown"
        if s == "mp4a" { return "aac" }
        return s.isEmpty ? "unknown" : s
    }

    // -------------------------------------------------------------- image

    private static func imageProbe(path: String, fileSize: Int64) -> [String: Any]? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0 else { return nil }
        let orientationRaw = props[kCGImagePropertyOrientation] as? Int ?? 1

        return [
            "path": path,
            "container": URL(fileURLWithPath: path).pathExtension.lowercased(),
            "durationMs": 0,
            "fileSizeBytes": Int(fileSize),
            "overallBitrate": 0,
            "videoStreams": [], // image info surfaced via metadata to keep schema stable
            "audioStreams": [],
            "metadata": [
                "imageWidth": "\(w)",
                "imageHeight": "\(h)",
                "orientation": "\(orientationRaw)",
                "type": "still-image",
            ],
            "estimatedSourceBitrate": 0,
            "hasBFrames": false,
        ]
    }
}
