package com.handbreak.handbreak

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.os.Build
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.io.FileOutputStream

/**
 * Image pipeline:  probe → decode (BitmapFactory, sampled if > max) →
 *                 orientation correct → resize (preserve aspect) → encode → validate.
 *
 * Mirrors HandBrake's still-image concepts (crop/scale, color, exif policy)
 * and validates compressedSize < originalSize when keepOriginalIfSmaller.
 */
object ImageTranscoder {

    data class Options(
        val quality: Int, // 0..100
        val maxWidth: Int?, val maxHeight: Int?,
        val format: String, // auto/jpeg/png/webp/heic/heif/avif
        val preserveExif: Boolean,
        val preserveAlpha: Boolean,
        val progressive: Boolean,
        val keepOriginalIfSmaller: Boolean
    )

    fun compress(
        inputPath: String, outputPath: String, opts: Options,
        jobId: String, jobManager: JobManager,
        onProgress: (Map<String, Any>) -> Unit
    ): Map<String, Any> {
        val start = System.currentTimeMillis()
        val inFile = File(inputPath)
        if (!inFile.exists()) throw IllegalArgumentException("Input not found: $inputPath")
        val outFile = File(outputPath)
        outFile.parentFile?.mkdirs()
        if (outFile.exists() && outFile.absolutePath == inFile.absolutePath)
            throw IllegalArgumentException("Input and output must differ")

        // probe
        val probe = probeImage(inputPath)
        val srcW = probe["width"] as Int
        val srcH = probe["height"] as Int
        val hasAlpha = probe["hasAlpha"] as Boolean
        val orientation = probe["orientation"] as Int // exif orientation degrees 0/90/180/270

        onProgress(mapOf("progress" to 0.05, "processedDurationMs" to 0, "totalDurationMs" to 1000,
            "encodedFrames" to 0, "totalFrames" to 1, "currentFps" to 0.0, "stage" to "decode"))

        // decode with sampling to avoid OOM on huge images
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(inputPath, bounds)
        var sample = 1
        // sample down if source vastly larger than target (avoid duplicate full-size buffers)
        if (opts.maxWidth != null || opts.maxHeight != null) {
            val targetW = opts.maxWidth ?: srcW
            val targetH = opts.maxHeight ?: srcH
            while ((bounds.outWidth / sample) > targetW * 2 || (bounds.outHeight / sample) > targetH * 2) sample *= 2
        }
        val decOpts = BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = if (hasAlpha && opts.preserveAlpha) Bitmap.Config.ARGB_8888 else Bitmap.Config.ARGB_8888 }
        var bitmap = BitmapFactory.decodeFile(inputPath, decOpts)
            ?: throw IllegalArgumentException("Failed to decode image: $inputPath")

        if (jobManager.isCancelled(jobId)) { bitmap.recycle(); throw VideoTranscoder.CancellationException("Cancelled") }

        // orientation correction (HandBrake's title->geometry rotation analogue for stills)
        if (orientation != 0) {
            val m = Matrix().apply { postRotate(orientation.toFloat()) }
            val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
            if (rotated != bitmap) { bitmap.recycle(); bitmap = rotated }
        }

        onProgress(mapOf("progress" to 0.4, "processedDurationMs" to 400, "totalDurationMs" to 1000,
            "encodedFrames" to 0, "totalFrames" to 1, "currentFps" to 0.0, "stage" to "filter"))

        // resize preserving aspect (never upscale unless explicitly larger target)
        val target = ResolutionHelper.calculate(
            srcWidth = bitmap.width, srcHeight = bitmap.height,
            maxWidth = opts.maxWidth, maxHeight = opts.maxHeight,
            targetWidth = null, targetHeight = null, scale = null,
            preserveAspectRatio = true
        )
        if (target.width != bitmap.width || target.height != bitmap.height) {
            val scaled = Bitmap.createScaledBitmap(bitmap, target.width, target.height, true)
            if (scaled != bitmap) { bitmap.recycle(); bitmap = scaled }
        }

        if (jobManager.isCancelled(jobId)) { bitmap.recycle(); throw VideoTranscoder.CancellationException("Cancelled") }

        // resolve format: auto picks best — png if alpha else jpeg.
        // Honesty (audit P1-7): a requested format we cannot encode (heic/avif)
        // falls back to JPEG AND is reported as JPEG with an explicit warning —
        // the result must never claim a codec that wasn't actually written.
        var resolvedFormat = when (opts.format.lowercase()) {
            "auto" -> if (hasAlpha && opts.preserveAlpha) "png" else "jpeg"
            else -> opts.format.lowercase()
        }
        val warnings = mutableListOf<String>()
        when (resolvedFormat) {
            "heic", "heif", "avif" -> {
                warnings.add("$resolvedFormat encoding unavailable on this device; wrote JPEG instead.")
                resolvedFormat = "jpeg"
            }
        }

        onProgress(mapOf("progress" to 0.6, "processedDurationMs" to 600, "totalDurationMs" to 1000,
            "encodedFrames" to 0, "totalFrames" to 1, "currentFps" to 0.0, "stage" to "encode"))

        val compressFormat: Bitmap.CompressFormat
        val outExt: String
        when (resolvedFormat) {
            "jpeg", "jpg" -> { compressFormat = Bitmap.CompressFormat.JPEG; outExt = ".jpg" }
            "png" -> { compressFormat = Bitmap.CompressFormat.PNG; outExt = ".png" }
            "webp" -> {
                compressFormat = if (Build.VERSION.SDK_INT >= 30) Bitmap.CompressFormat.WEBP_LOSSY else Bitmap.CompressFormat.WEBP
                outExt = ".webp"
            }
            else -> { compressFormat = Bitmap.CompressFormat.JPEG; outExt = ".jpg" }
        }

        // ensure output path extension matches resolved format
        val finalOut = if (outFile.extension.lowercase() != outExt.trimStart('.')) {
            File(outFile.parent, outFile.nameWithoutExtension + outExt)
        } else outFile

        // encode — JPEG quality 0..100, PNG ignores quality (we still pass correctly)
        val qualityInt = opts.quality.coerceIn(0, 100)
        val outW = bitmap.width
        val outH = bitmap.height
        var wrote = false
        FileOutputStream(finalOut).use { fos ->
            wrote = bitmap.compress(compressFormat, qualityInt, fos)
        }
        bitmap.recycle()
        if (!wrote) throw IllegalStateException("Bitmap.compress failed")

        // progressive JPEG: Android Bitmap doesn't support progressive directly — would need libjpeg-turbo; documented as future.

        onProgress(mapOf("progress" to 0.9, "processedDurationMs" to 900, "totalDurationMs" to 1000,
            "encodedFrames" to 1, "totalFrames" to 1, "currentFps" to 1.0, "stage" to "mux"))

        // validate + keepOriginalIfSmaller
        if (!finalOut.exists() || finalOut.length() == 0L) throw IllegalStateException("Image encode produced no output")
        if (opts.keepOriginalIfSmaller && finalOut.length() >= inFile.length()) {
            finalOut.delete()
            return mapOf(
                "inputPath" to inputPath,
                "outputPath" to inputPath,
                "originalSizeBytes" to inFile.length(),
                "outputSizeBytes" to inFile.length(),
                "savedBytes" to 0,
                "compressionRatio" to 1.0,
                "compressionPercentage" to 0.0,
                "durationMs" to (System.currentTimeMillis() - start).toInt(),
                "usedHardwareAcceleration" to false,
                "codec" to resolvedFormat,
                "container" to resolvedFormat,
                "qualityWarning" to if (warnings.isEmpty()) null else warnings.joinToString(" "),
                "wasKeptOriginal" to true
            )
        }

        // preserve EXIF if requested and JPEG — write ACTUAL output dimensions
        // (audit P2-4: source width/height tags were wrong after resize)
        if (opts.preserveExif && resolvedFormat == "jpeg") {
            try {
                val srcExif = ExifInterface(inputPath)
                val dstExif = ExifInterface(finalOut.absolutePath)
                val tags = arrayOf(ExifInterface.TAG_DATETIME, ExifInterface.TAG_GPS_LATITUDE, ExifInterface.TAG_GPS_LONGITUDE,
                    ExifInterface.TAG_MAKE, ExifInterface.TAG_MODEL)
                for (t in tags) srcExif.getAttribute(t)?.let { dstExif.setAttribute(t, it) }
                dstExif.setAttribute(ExifInterface.TAG_IMAGE_WIDTH, outW.toString())
                dstExif.setAttribute(ExifInterface.TAG_IMAGE_LENGTH, outH.toString())
                dstExif.setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL.toString())
                dstExif.saveAttributes()
            } catch (_: Exception) {}
        }

        onProgress(mapOf("progress" to 1.0, "processedDurationMs" to 1000, "totalDurationMs" to 1000,
            "encodedFrames" to 1, "totalFrames" to 1, "currentFps" to 1.0, "stage" to "validate"))

        val outSize = finalOut.length()
        val origSize = inFile.length()
        val saved = (origSize - outSize).coerceAtLeast(0)
        val ratio = if (outSize > 0) origSize.toDouble() / outSize else 1.0
        val pct = if (origSize > 0) saved.toDouble() / origSize * 100 else 0.0

        return mapOf(
            "inputPath" to inputPath,
            "outputPath" to finalOut.absolutePath,
            "originalSizeBytes" to origSize,
            "outputSizeBytes" to outSize,
            "savedBytes" to saved,
            "compressionRatio" to ratio,
            "compressionPercentage" to pct,
            "durationMs" to (System.currentTimeMillis() - start).toInt(),
            "usedHardwareAcceleration" to false,
            "codec" to resolvedFormat,
            "container" to resolvedFormat,
            "qualityWarning" to if (warnings.isEmpty()) null else warnings.joinToString(" "),
            "wasKeptOriginal" to false
        )
    }

    private fun probeImage(path: String): Map<String, Any> {
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, opts)
        if (opts.outWidth <= 0 || opts.outHeight <= 0) throw IllegalArgumentException("Not a decodable image: $path")
        var orientation = 0
        var hasAlpha = false
        try {
            val exif = ExifInterface(path)
            orientation = when (exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90
                ExifInterface.ORIENTATION_ROTATE_180 -> 180
                ExifInterface.ORIENTATION_ROTATE_270 -> 270
                else -> 0
            }
        } catch (_: Exception) {}
        // hasAlpha: check mime type
        val mime = opts.outMimeType ?: ""
        hasAlpha = mime.contains("png", true) || mime.contains("webp", true)
        return mapOf("width" to opts.outWidth, "height" to opts.outHeight, "orientation" to orientation, "hasAlpha" to hasAlpha, "mime" to mime)
    }
}
