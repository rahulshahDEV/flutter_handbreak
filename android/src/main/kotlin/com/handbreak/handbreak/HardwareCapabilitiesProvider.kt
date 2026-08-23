package com.handbreak.handbreak

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build

/**
 * Runtime hardware encode detection — the real check HandBrake does via
 * hwaccel_can_use_full_pipeline, but on mobile we enumerate MediaCodecList.
 *
 * We verify hardware by filtering isEncoder && !isSoftwareOnly (API 29+).
 * On older OS where isSoftwareOnly unavailable we heuristically treat
 * known software codec names (OMX.google.*) as software.
 */
object HardwareCapabilitiesProvider {

    fun get(): Map<String, Any> {
        val list = MediaCodecList(MediaCodecList.ALL_CODECS)
        var h264Hw = false
        var hevcHw = false
        var av1Hw = false
        var vp9Hw = false
        var hwDecode = false
        val details = mutableMapOf<String, Any>()

        for (info in list.codecInfos) {
            val isEncoder = info.isEncoder
            val isHardware: Boolean = if (Build.VERSION.SDK_INT >= 29) {
                // isSoftwareOnly reflects true HW on Q+
                try { !info.isSoftwareOnly } catch (_: Exception) { !isSoftwareCodec(info.name) }
            } else {
                !isSoftwareCodec(info.name)
            }

            for (type in info.supportedTypes) {
                val t = type.lowercase()
                when {
                    t == "video/avc" && isEncoder && isHardware -> h264Hw = true
                    t == "video/hevc" && isEncoder && isHardware -> hevcHw = true
                    t == "video/av01" && isEncoder && isHardware -> av1Hw = true
                    t == "video/x-vnd.on2.vp9" && isEncoder && isHardware -> vp9Hw = true
                }
                // P1-2: hardware DECODE capability counts only for video mimes.
                if (!isEncoder && isHardware && t.startsWith("video/")) hwDecode = true
            }
        }

        // Also probe decoder names for reporting
        details["allCodecsChecked"] = list.codecInfos.size
        details["os"] = "android ${Build.VERSION.SDK_INT}"

        return mapOf(
            "supportsHardwareH264Encode" to h264Hw,
            "supportsHardwareH265Encode" to hevcHw,
            "supportsHardwareAv1Encode" to av1Hw,
            "supportsHardwareVp9Encode" to vp9Hw,
            "supportsHardwareDecode" to hwDecode,
            "platform" to "android",
            "details" to details
        )
    }

    private fun isSoftwareCodec(name: String): Boolean {
        val n = name.lowercase()
        return n.startsWith("omx.google.") || n.contains(".sw.") || n.contains("software")
    }

    /** Whether a given mime has *any* hardware encoder (for fallback decision). */
    fun hasHardwareEncoderFor(mime: String): Boolean {
        val target = mime.lowercase()
        val list = MediaCodecList(MediaCodecList.ALL_CODECS)
        for (info in list.codecInfos) {
            if (!info.isEncoder) continue
            val isHw = if (Build.VERSION.SDK_INT >= 29) {
                try { !info.isSoftwareOnly } catch (_: Exception) { !isSoftwareCodec(info.name) }
            } else !isSoftwareCodec(info.name)
            if (!isHw) continue
            if (info.supportedTypes.any { it.equals(target, ignoreCase = true) }) return true
        }
        return false
    }
}
