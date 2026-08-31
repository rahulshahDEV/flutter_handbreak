package com.handbreak.handbreak

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import java.io.File
import java.nio.ByteBuffer

/**
 * Robust probe — mirrors HandBrake's scan.c title scan.
 * Uses MediaExtractor (no FFmpeg/GPL) to emit geometry/rotation/color/hdr/stream counts.
 * Falls back to MediaMetadataRetriever for duration/container when extractor fails.
 *
 * All rotation handling: MediaFormat KEY_ROTATION is applied so reported width/height are
 * rotation-corrected (like HandBrake's job->width/height after geometry fix).
 */
object MediaProbe {

    fun probe(path: String): Map<String, Any?> {
        val file = File(path)
        if (!file.exists()) throw IllegalArgumentException("File not found: $path")
        val fileSize = file.length()

        val extractor = MediaExtractor()
        var container = guessContainer(path)
        var durationMs = 0L
        var overallBitrate = 0
        val videoStreams = mutableListOf<Map<String, Any?>>()
        val audioStreams = mutableListOf<Map<String, Any?>>()
        val metadata = mutableMapOf<String, String>()
        var hasBFrames = false

        try {
            extractor.setDataSource(path)
            val trackCount = extractor.trackCount
            for (i in 0 until trackCount) {
                val fmt = extractor.getTrackFormat(i)
                val mime = fmt.getString(MediaFormat.KEY_MIME) ?: "unknown"
                when {
                    mime.startsWith("video/") -> {
                        val rawW = safeInt(fmt, MediaFormat.KEY_WIDTH, 0)
                        val rawH = safeInt(fmt, MediaFormat.KEY_HEIGHT, 0)
                        // KEY_ROTATION is often absent from extractor output; fall back to
                        // MediaMetadataRetriever's video rotation (tkhd matrix on ISO-BMFF).
                        var rotation = safeInt(fmt, MediaFormat.KEY_ROTATION, -1)
                        if (rotation < 0) {
                            rotation = retrieveRotation(path)
                            if (rotation < 0) rotation = 0
                        }
                        // rotation-corrected dimensions (HandBrake does this in scan)
                        val (w, h) = if (rotation == 90 || rotation == 270) rawH to rawW else rawW to rawH
                        val fps = run {
                            val f = if (fmt.containsKey(MediaFormat.KEY_FRAME_RATE)) safeInt(fmt, MediaFormat.KEY_FRAME_RATE, 0) else 0
                            f.toDouble()
                        }
                        val avgFps = fps
                        // bitrate: KEY_BIT_RATE may be absent; estimate from file size/duration later
                        val br = safeInt(fmt, MediaFormat.KEY_BIT_RATE, 0)
                        val durUs = safeLong(fmt, MediaFormat.KEY_DURATION, 0L)
                        if (durUs > durationMs * 1000) durationMs = durUs / 1000
                        val colorStandard = if (fmt.containsKey("color-standard")) fmt.getInteger("color-standard").toString() else "unknown"
                        val colorRange = if (fmt.containsKey("color-range")) fmt.getInteger("color-range").toString() else "unknown"
                        val colorTransfer = if (fmt.containsKey("color-transfer")) fmt.getInteger("color-transfer").toString() else "unknown"
                        val isHdr = isHdrMime(fmt, mime)

                        // detect durationMs from extractor as well
                        videoStreams.add(mapOf(
                            "index" to i,
                            "codec" to mimeToCodec(mime),
                            "codecString" to mime,
                            "width" to w,
                            "height" to h,
                            "rotation" to rotation,
                            "frameRate" to fps,
                            "averageFrameRate" to avgFps,
                            "isVariableFrameRate" to false, // MediaExtractor doesn't expose VFR directly; treat as CFR
                            "durationMs" to (durUs / 1000).toInt(),
                            "bitRate" to br,
                            "pixelFormat" to "yuv420p",
                            "colorPrimaries" to colorStandard,
                            "colorTransfer" to colorTransfer,
                            "colorMatrix" to "unknown",
                            "colorRange" to colorRange,
                            "bitDepth" to 8,
                            "isHdr" to isHdr,
                            "hdrType" to if (isHdr) "hdr10" else null,
                            "displayAspectRatio" to if (h != 0) w.toDouble() / h else 0.0,
                            "sampleAspectRatio" to 1.0,
                            "profile" to null,
                            "level" to null
                        ))
                        // hasBFrames hint: not exposed; default false
                    }
                    mime.startsWith("audio/") -> {
                        val sr = safeInt(fmt, MediaFormat.KEY_SAMPLE_RATE, 0)
                        val ch = safeInt(fmt, MediaFormat.KEY_CHANNEL_COUNT, 0)
                        val br = safeInt(fmt, MediaFormat.KEY_BIT_RATE, 0)
                        val lang = try { fmt.getString(MediaFormat.KEY_LANGUAGE) } catch (_: Exception) { null }
                        audioStreams.add(mapOf(
                            "index" to i,
                            "codec" to mimeToCodec(mime),
                            "codecString" to mime,
                            "sampleRate" to sr,
                            "channelCount" to ch,
                            "bitRate" to br,
                            "language" to lang,
                            "channelLayout" to if (ch == 1) "mono" else if (ch == 2) "stereo" else "${ch}ch"
                        ))
                    }
                }
            }

            // overall duration from retriever if extractor didn't yield it
            if (durationMs == 0L) {
                durationMs = retrieveDurationMs(path)
            }

            // Truncation guard: moov-fronted files parse fine even when badly cut short.
            // Compare the last video/audio sample PTS with the declared duration —
            // a large gap means the media data is missing (corrupt/truncated input).
            val firstVideo = videoStreams.firstOrNull()
            if (firstVideo != null) {
                val declaredUs = (firstVideo["durationMs"] as? Int ?: 0) * 1000L
                if (declaredUs > 0) {
                    val lastPtsUs = lastSampleTimeUs(extractor, firstVideo["index"] as Int)
                    if (lastPtsUs in 1 until declaredUs / 2) {
                        throw IllegalArgumentException(
                            "Truncated media: playable ${lastPtsUs / 1000}ms of ${declaredUs / 1000}ms",
                        )
                    }
                }
            }
            // container already guessed; could refine via extractor
        } catch (e: Exception) {
            // If extractor fails completely (corrupt), try retriever path
            if (durationMs == 0L) durationMs = retrieveDurationMs(path)
            if (videoStreams.isEmpty() && audioStreams.isEmpty()) {
                throw IllegalArgumentException("Unsupported or corrupt media: ${e.message}")
            }
        } finally {
            extractor.release()
        }

        if (durationMs > 0) {
            // Audit P2-1/P2-2: clamp against Int overflow for gigantic files/durations.
            val clampedDurMs = durationMs.coerceIn(1, 31_536_000_000L) // 1s..1000 years
            overallBitrate = ((fileSize * 8 * 1000) / clampedDurMs).coerceIn(0, 400_000_000).toInt()
        }

        return mapOf(
            "path" to path,
            "container" to container,
            "durationMs" to durationMs.coerceIn(0, Int.MAX_VALUE.toLong()).toInt(),
            "fileSizeBytes" to fileSize,
            "overallBitrate" to overallBitrate,
            "videoStreams" to videoStreams,
            "audioStreams" to audioStreams,
            "metadata" to metadata,
            "estimatedSourceBitrate" to overallBitrate,
            "hasBFrames" to hasBFrames
        )
    }

    private fun retrieveDurationMs(path: String): Long {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(path)
            val d = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            d
        } catch (_: Exception) { 0L } finally { try { r.release() } catch (_: Exception) {} }
    }

    /** Rotation in degrees (0/90/180/270) from the container matrix; -1 when unknown. */
    private fun retrieveRotation(path: String): Int {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(path)
            r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: -1
        } catch (_: Exception) { -1 } finally { try { r.release() } catch (_: Exception) {} }
    }

    /** Timestamp (µs) of the last sample on the track, without decoding. -1 if unreadable. */
    private fun lastSampleTimeUs(extractor: MediaExtractor, trackIndex: Int): Long {
        return try {
            extractor.selectTrack(trackIndex)
            var last = -1L
            val buf = MediaCodec.BufferInfo()
            while (true) {
                val idx = extractor.sampleTrackIndex
                if (idx < 0) break
                val size = extractor.readSampleData(ByteBuffer.allocate(1 shl 16), 0)
                if (size < 0) break
                last = extractor.sampleTime
                if (!extractor.advance()) break
            }
            last
        } catch (_: Exception) { -1L }
    }

    private fun guessContainer(path: String): String {
        val ext = path.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "mp4", "m4v" -> "mp4"
            "mov" -> "mov"
            "mkv" -> "mkv"
            "webm" -> "webm"
            "avi" -> "avi"
            "3gp" -> "3gp"
            else -> ext.ifEmpty { "unknown" }
        }
    }

    private fun mimeToCodec(mime: String): String = when (mime.lowercase()) {
        "video/avc", "video/h264" -> "h264"
        "video/hevc", "video/h265" -> "h265"
        "video/av01" -> "av1"
        "video/x-vnd.on2.vp9", "video/vp9" -> "vp9"
        "audio/mp4a-latm", "audio/aac" -> "aac"
        "audio/opus" -> "opus"
        "audio/vorbis" -> "vorbis"
        "audio/mpeg" -> "mp3"
        else -> mime.substringAfter('/')
    }

    private fun isHdrMime(fmt: MediaFormat, mime: String): Boolean {
        // Heuristic: check for HDR keys present in MediaFormat on Android 13+
        return try {
            if (fmt.containsKey("hdr-static-info")) return true
            // also CHECK mime that could be HDR profile: not reliable without parsing sps
            false
        } catch (_: Exception) { false }
    }

    private fun safeInt(fmt: MediaFormat, key: String, def: Int): Int = try {
        if (fmt.containsKey(key)) fmt.getInteger(key) else def
    } catch (_: Exception) { def }

    private fun safeLong(fmt: MediaFormat, key: String, def: Long): Long = try {
        if (fmt.containsKey(key)) fmt.getLong(key) else def
    } catch (_: Exception) { def }

}
