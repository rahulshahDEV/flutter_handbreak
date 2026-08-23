import UIKit
import VideoToolbox

/// Hardware capability detection — REAL probes, no assumptions (spec §12).
///
/// Encode: creates a VTCompressionSession *requiring* hardware. If creation
/// fails, hardware encode for that codec is genuinely unavailable.
/// Decode: VTIsHardwareDecodeSupported.
enum HardwareCapabilitiesProvider {

    /// VTIsHardwareDecodeSupported is iOS 8+; pod targets 13+, so a direct call is safe.
    private static func decodeSupported(_ codec: CMVideoCodecType) -> Bool {
        VTIsHardwareDecodeSupported(codec)
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// TRUE encode-capability probe via session creation with hardware required.
    /// Returns false on simulator (no hardware encoders there).
    static func vtHardwareEncodeSupported(_ codecType: CMVideoCodecType) -> Bool {
        if isSimulator { return false }
        var session: VTCompressionSession?
        // Raw key strings — the typed kVT* constants are annotated iOS 17.4+
        // in recent SDKs, but these documented keys exist since iOS 8.
        let spec: CFDictionary = [
            "EnableHardwareAcceleratedVideoEncoder" as NSString: true,
            "RequireHardwareAcceleratedVideoEncoder" as NSString: true,
        ] as CFDictionary
        // 720p probe size — universally supported dimensions; avoids 4K edge cases.
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 1280, height: 720,
            codecType: codecType,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)
        if let s = session {
            VTCompressionSessionInvalidate(s)
        }
        return status == noErr && session != nil
    }

    static func get() -> [String: Any] {        let h264Enc = vtHardwareEncodeSupported(kCMVideoCodecType_H264)
        var hevcEnc = false
        var av1Enc = false
        if #available(iOS 11.0, *) {
            hevcEnc = vtHardwareEncodeSupported(kCMVideoCodecType_HEVC)
        }
        if #available(iOS 17.0, *) {
            av1Enc = vtHardwareEncodeSupported(kCMVideoCodecType_AV1)
        }
        let h264Dec = decodeSupported(kCMVideoCodecType_H264)
        let hevcDec = decodeSupported(kCMVideoCodecType_HEVC)

        return [
            "supportsHardwareH264Encode": h264Enc,
            "supportsHardwareH265Encode": hevcEnc,
            "supportsHardwareAv1Encode": av1Enc,
            "supportsHardwareVp9Encode": false, // VP9 HW encode not exposed on iOS
            "supportsHardwareDecode": h264Dec || hevcDec,
            "platform": "ios",
            "details": [
                "os": UIDevice.current.systemVersion,
                "probe": "VTCompressionSession(hardware-required) + VTIsHardwareDecodeSupported",
                "simulator": isSimulator,
            ] as [String: Any],
        ]
    }
}
