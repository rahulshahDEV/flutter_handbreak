package com.handbreak.handbreak

import kotlin.math.roundToInt

/**
 * Mirrors Dart's ResolutionCalculator for native use — single source of truth for
 * encoder width/height. HandBrake: modulus 2, never 0, preserve aspect by default.
 */
object ResolutionHelper {

    data class Size(val width: Int, val height: Int)

    fun calculate(
        srcWidth: Int, srcHeight: Int,
        maxWidth: Int?, maxHeight: Int?,
        targetWidth: Int?, targetHeight: Int?,
        scale: Double?,
        preserveAspectRatio: Boolean = true,
        allowStretch: Boolean = false,
        modulus: Int = 2
    ): Size {
        require(srcWidth > 0 && srcHeight > 0)
        val aspect = srcWidth.toDouble() / srcHeight
        var w = srcWidth
        var h = srcHeight

        when {
            targetWidth != null || targetHeight != null -> {
                if (!preserveAspectRatio || allowStretch) {
                    w = targetWidth ?: (targetHeight!! * aspect).roundToInt()
                    h = targetHeight ?: (targetWidth!! / aspect).roundToInt()
                } else {
                    if (targetWidth != null && targetHeight != null) {
                        val ta = targetWidth.toDouble() / targetHeight
                        if (aspect > ta) { w = targetWidth; h = (w / aspect).roundToInt() }
                        else { h = targetHeight; w = (h * aspect).roundToInt() }
                    } else if (targetWidth != null) {
                        w = targetWidth; h = (w / aspect).roundToInt()
                    } else {
                        h = targetHeight!!; w = (h * aspect).roundToInt()
                    }
                }
            }
            scale != null -> {
                w = (srcWidth * scale).roundToInt()
                h = (srcHeight * scale).roundToInt()
            }
            else -> {
                if (maxWidth != null && w > maxWidth) { w = maxWidth; h = (w / aspect).roundToInt() }
                if (maxHeight != null && h > maxHeight) { h = maxHeight; w = (h * aspect).roundToInt() }
            }
        }

        w = align(w, modulus); h = align(h, modulus)
        w = w.coerceIn(modulus, 7680); h = h.coerceIn(modulus, 7680)

        val isExplicit = targetWidth != null || targetHeight != null || scale != null
        if (!isExplicit && (w > srcWidth || h > srcHeight)) {
            w = align(srcWidth, modulus); h = align(srcHeight, modulus)
        }
        return Size(w, h)
    }

    private fun align(v: Int, mod: Int): Int {
        if (mod <= 1) return v.coerceAtLeast(1)
        return ((v + mod - 1) / mod) * mod
    }
}
