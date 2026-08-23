import UIKit
import CoreMedia

/// Shared typed error bridging native failures to Dart's HandbreakException mapping.
struct ProbeError: Error {
    let code: String
    let message: String
}

/// Mirror of Dart `ResolvedPlan` — the native side executes this; it does not re-derive policy.
struct ResolvedPlan {
    let width: Int
    let height: Int
    let sourceFps: Double
    let targetFps: Double
    let limitFrameRate: Bool
    let container: String          // mp4 | mov | webm | 3gp
    let containerFallbackNote: String?
    let useHardware: Bool
    let hwFallbackNote: String?
    let rateControlMode: String    // cq | cq_value | abr
    let crf: Double?
    let bitrateKbps: Int?
    let audioMode: String          // passthrough | transcode | remove
    let audioCodec: String         // aac | opus | none
    let audioBitrateKbps: Int

    static func fromOptions(_ options: [String: Any]) -> ResolvedPlan? {
        guard let m = options["plan"] as? [String: Any],
              let w = m["width"] as? Int,
              let h = m["height"] as? Int else { return nil }
        let audio = m["audio"] as? [String: Any]
        return ResolvedPlan(
            width: w,
            height: h,
            sourceFps: m["sourceFps"] as? Double ?? 30,
            targetFps: m["targetFps"] as? Double ?? 30,
            limitFrameRate: m["limitFrameRate"] as? Bool ?? false,
            container: m["container"] as? String ?? "mp4",
            containerFallbackNote: m["containerFallbackNote"] as? String,
            useHardware: m["useHardware"] as? Bool ?? false,
            hwFallbackNote: m["hwFallbackNote"] as? String,
            rateControlMode: m["rateControlMode"] as? String ?? "cq",
            crf: m["crf"] as? Double,
            bitrateKbps: m["bitrateKbps"] as? Int,
            audioMode: audio?["mode"] as? String ?? "transcode",
            audioCodec: audio?["codec"] as? String ?? "aac",
            audioBitrateKbps: audio?["bitrateKbps"] as? Int ?? 128
        )
    }

    var notes: [String] {
        [containerFallbackNote, hwFallbackNote].compactMap { $0 }
    }
}

/// Geometry math identical to Dart ResolutionCalculator / Android ResolutionHelper.
enum ResolutionHelper {
    struct Size { let width: Int; let height: Int }

    static func calculate(srcWidth: Int, srcHeight: Int,
                          maxWidth: Int?, maxHeight: Int?,
                          targetWidth: Int?, targetHeight: Int?,
                          scale: Double?,
                          preserveAspectRatio: Bool = true,
                          allowStretch: Bool = false,
                          modulus: Int = 2) -> Size {
        let aspect = Double(srcWidth) / Double(srcHeight)
        var w = srcWidth, h = srcHeight

        if targetWidth != nil || targetHeight != nil {
            if !preserveAspectRatio || allowStretch {
                w = targetWidth ?? Int((Double(targetHeight!) * aspect).rounded())
                h = targetHeight ?? Int((Double(targetWidth!) / aspect).rounded())
            } else if let tw = targetWidth, let th = targetHeight {
                let ta = Double(tw) / Double(th)
                if aspect > ta { w = tw; h = Int((Double(w) / aspect).rounded()) }
                else { h = th; w = Int((Double(h) * aspect).rounded()) }
            } else if let tw = targetWidth {
                w = tw; h = Int((Double(w) / aspect).rounded())
            } else {
                h = targetHeight!; w = Int((Double(h) * aspect).rounded())
            }
        } else if let s = scale {
            w = Int((Double(srcWidth) * s).rounded())
            h = Int((Double(srcHeight) * s).rounded())
        } else {
            if let mw = maxWidth, w > mw { w = mw; h = Int((Double(w) / aspect).rounded()) }
            if let mh = maxHeight, h > mh { h = mh; w = Int((Double(h) * aspect).rounded()) }
        }

        func align(_ v: Int) -> Int { ((v + modulus - 1) / modulus) * modulus }
        w = min(max(align(w), modulus), 7680)
        h = min(max(align(h), modulus), 7680)

        let explicitUpscale = targetWidth != nil || targetHeight != nil || scale != nil
        if !explicitUpscale && (w > srcWidth || h > srcHeight) {
            w = align(srcWidth); h = align(srcHeight)
        }
        return Size(width: w, height: h)
    }
}
