package com.handbreak.handbreak

import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.ArrayDeque
import kotlin.math.roundToInt

/**
 * Production video pipeline (v2) — executes the [Plan] resolved by Dart's EncodePlanResolver:
 *
 *   demux(MediaExtractor) ─► decode(MediaCodec, Surface|ByteBuffer)
 *        │                          │  ← PTS frame-rate gate (drop-only, never duplicates)
 *        │                          ▼
 *        ├─ audio passthrough ──► [PTS interleaver] ─► MediaMuxer(effective container)
 *        └─ audio AAC transcode ─┘        ▲
 *                                         │
 *                            encode(MediaCodec HW/SW, plan crf/bitrate)
 *
 * Correctness contract:
 * - All policy lives in Dart's plan; natives execute and report honestly.
 * - Single owner thread; cooperative cancellation checked between stages.
 * - Every resource released exactly once in finally (success/cancel/error).
 * - Bounded memory: codec pipelines provide natural backpressure; interleave
 *   queues pause PRODUCTION (not consumption) when full.
 * - Temp file + atomic rename; input file never modified.
 * - Output re-probed before success is reported (exit-code alone insufficient).
 */
object VideoTranscoder {

    class CancellationException(msg: String) : Exception(msg)
    class OutputValidationException(msg: String) : Exception(msg)
    /** Dedicated stall/timeout failure — mapped to TIMEOUT at the plugin boundary. */
    class StallException(msg: String) : Exception(msg)

    // ------------------------------------------------------------------ plan

    /** Parsed mirror of Dart ResolvedPlan. */
    data class Plan(
        val width: Int,
        val height: Int,
        val sourceFps: Double,
        val targetFps: Double,
        val limitFrameRate: Boolean,
        val container: String,
        val useHardware: Boolean,
        val rateControlMode: String, // cq | cq_value | abr
        val crf: Double?,
        val bitrateKbps: Int?,
        val audioMode: String,       // passthrough | transcode | remove
        val audioCodec: String,      // aac | opus | none
        val audioBitrateKbps: Int,
    ) {
        companion object {
            fun fromMap(m: Map<String, Any>?): Plan? {
                if (m == null) return null
                val w = (m["width"] as? Number)?.toInt() ?: return null
                val h = (m["height"] as? Number)?.toInt() ?: return null
                @Suppress("UNCHECKED_CAST")
                val audio = m["audio"] as? Map<String, Any>
                return Plan(
                    width = w,
                    height = h,
                    sourceFps = (m["sourceFps"] as? Number)?.toDouble() ?: 30.0,
                    targetFps = (m["targetFps"] as? Number)?.toDouble() ?: 30.0,
                    limitFrameRate = m["limitFrameRate"] as? Boolean ?: false,
                    container = m["container"] as? String ?: "mp4",
                    useHardware = m["useHardware"] as? Boolean ?: false,
                    rateControlMode = m["rateControlMode"] as? String ?: "cq",
                    crf = (m["crf"] as? Number)?.toDouble(),
                    bitrateKbps = (m["bitrateKbps"] as? Number)?.toInt(),
                    audioMode = audio?.get("mode") as? String ?: "transcode",
                    audioCodec = audio?.get("codec") as? String ?: "aac",
                    audioBitrateKbps = (audio?.get("bitrateKbps") as? Number)?.toInt() ?: 128,
                )
            }
        }
    }

    /** Raw option map carrier; legacy heuristics parsed only when plan absent. */
    class Options(val raw: Map<String, Any>) {
        private val s = { k: String, d: String -> raw[k] as? String ?: d }
        private val b = { k: String, d: Boolean -> raw[k] as? Boolean ?: d }

        val codec get() = s("codec", "h264")
        val hardwareAcceleration get() = s("hardwareAcceleration", "auto")
        val keepOriginalIfSmaller get() = b("keepOriginalIfSmaller", false)

        @Suppress("UNCHECKED_CAST")
        val plan: Plan? by lazy { Plan.fromMap(raw["plan"] as? Map<String, Any>) }

        /** Legacy-only fields (used exclusively when plan == null). */
        val maxWidth get() = (raw["maxWidth"] as? Number)?.toInt()
        val maxHeight get() = (raw["maxHeight"] as? Number)?.toInt()
        val targetWidth get() = (raw["targetWidth"] as? Number)?.toInt()
        val targetHeight get() = (raw["targetHeight"] as? Number)?.toInt()
        val scale get() = (raw["scale"] as? Number)?.toDouble()
        val frameRateMode get() = s("frameRateMode", "sameAsSource")
        val maxFrameRate get() = (raw["maxFrameRate"] as? Number)?.toDouble()

        @Suppress("UNCHECKED_CAST")
        val legacyCrf: Double?
            get() {
                val rc = raw["rateControl"] as? Map<String, Any> ?: return null
                return when (rc["mode"]) {
                    "cq" -> qualityNameToCrf(rc["quality"] as? String ?: "medium", codec)
                    "cq_value" -> (rc["value"] as? Number)?.toDouble()
                    else -> null
                } ?: ((raw["advanced"] as? Map<String, Any>)?.get("crf") as? Number)?.toDouble()
            }

        @Suppress("UNCHECKED_CAST")
        val legacyAbrKbps: Int?
            get() = ((raw["rateControl"] as? Map<String, Any>)?.get("bitrateKbps") as? Number)?.toInt()

        @Suppress("UNCHECKED_CAST")
        val legacyAudioMode: String
            get() = (((raw["audio"] as? Map<String, Any>)?.get("mode")) as? String) ?: "encode"

        @Suppress("UNCHECKED_CAST")
        val legacyAudioCodec: String
            get() = (((raw["audio"] as? Map<String, Any>)?.get("codec")) as? String) ?: "aac"

        @Suppress("UNCHECKED_CAST")
        val legacyAudioBitrateKbps: Int
            get() = (((raw["audio"] as? Map<String, Any>)?.get("bitrateKbps")) as? Number)?.toInt() ?: 128

        companion object {
            fun qualityNameToCrf(name: String, codec: String): Double = when (codec.lowercase()) {
                "h265", "hevc" -> when (name) { "veryHigh" -> 20.0; "high" -> 22.0; "medium" -> 25.0; "low" -> 28.0; else -> 25.0 }
                "av1" -> when (name) { "veryHigh" -> 28.0; "high" -> 32.0; "medium" -> 38.0; "low" -> 44.0; else -> 38.0 }
                "vp9" -> when (name) { "veryHigh" -> 30.0; "high" -> 34.0; "medium" -> 40.0; "low" -> 46.0; else -> 40.0 }
                else -> when (name) { "veryHigh" -> 18.0; "high" -> 20.0; "medium" -> 23.0; "low" -> 26.0; else -> 23.0 }
            }
        }
    }

    // -------------------------------------------------------------- entry

    fun transcode(
        inputPath: String,
        outputPath: String,
        optsRaw: Map<String, Any>,
        jobId: String,
        jobManager: JobManager,
        onProgress: (Map<String, Any>) -> Unit,
    ): Map<String, Any> {
        val startMs = System.currentTimeMillis()
        val opts = Options(optsRaw)
        val inFile = File(inputPath)
        if (!inFile.exists()) throw IllegalArgumentException("Input not found: $inputPath")
        if (inFile.absolutePath == File(outputPath).absolutePath)
            throw IllegalArgumentException("Input and output must differ")

        // ---- probe once ----
        val probeInfo = MediaProbe.probe(inputPath)
        val streams = probeVideoStreams(probeInfo)
        if (streams.isEmpty()) throw IllegalArgumentException("No decodable video stream")
        val srcW = streams[0]["width"] as Int
        val srcH = streams[0]["height"] as Int
        val rotation = streams[0]["rotation"] as Int

        // ---- effective config (plan wins; legacy fallback for pre-plan callers) ----
        val plan = opts.plan
        val resolvedSize = ResolutionHelper.calculate(
            srcWidth = srcW, srcHeight = srcH,
            maxWidth = opts.maxWidth, maxHeight = opts.maxHeight,
            targetWidth = opts.targetWidth, targetHeight = opts.targetHeight,
            scale = opts.scale, preserveAspectRatio = true, allowStretch = false,
        )
        val outW = plan?.width ?: resolvedSize.width
        val outH = plan?.height ?: resolvedSize.height
        val srcFps = plan?.sourceFps ?: 30.0
        val targetFps = plan?.targetFps ?: run {
            val mf = opts.maxFrameRate
            if (opts.frameRateMode != "variable" && mf != null && mf < srcFps) mf else srcFps
        }
        val limitFrameRate = plan?.limitFrameRate
            ?: (opts.frameRateMode != "variable" && opts.maxFrameRate != null && opts.maxFrameRate!! < srcFps)
        val effectiveContainer = plan?.container ?: opts.container
        val rcMode = plan?.rateControlMode
            ?: (if (opts.legacyCrf != null) "cq_value" else if (opts.legacyAbrKbps != null) "abr" else "cq")
        val crf = plan?.crf ?: opts.legacyCrf
        val abrKbps = plan?.bitrateKbps ?: opts.legacyAbrKbps
        val audioMode = plan?.audioMode ?: when (opts.legacyAudioMode) {
            "copy" -> "passthrough"; "remove" -> "remove"; else -> "transcode"
        }
        val audioBrKbps = plan?.audioBitrateKbps ?: opts.legacyAudioBitrateKbps

        val mime = mimeFor(opts.codec)
        val outFile = File(outputPath)
        outFile.parentFile?.mkdirs()
        val durationMs = (probeInfo["durationMs"] as Int).toLong().coerceAtLeast(0)
        val durationUs = durationMs * 1000
        val estTotalFrames = ((durationMs / 1000.0) * targetFps).toLong().coerceAtLeast(1L)

        val tmpFile = File("$outputPath.hbtmp.$jobId")
        if (tmpFile.exists()) tmpFile.delete()
        // Defense-in-depth (audit P2-5): never clobber an existing destination
        // unless the caller explicitly allowed overwrite.
        val overwriteExisting = optsRaw["overwriteExisting"] as? Boolean ?: false
        if (outFile.exists() && !overwriteExisting) {
            throw IllegalStateException("Output already exists: $outputPath (set overwriteExisting=true to replace)")
        }

        val notes = mutableListOf<String>()
        plan?.containerFallbackNote()?.let(notes::add)
        plan?.hwFallbackNote()?.let(notes::add)

        val requireHw = opts.hardwareAcceleration == "hardwareOnly"

        var videoExtractor: MediaExtractor? = null
        var audioExtractor: MediaExtractor? = null
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var encoderSurface: Surface? = null
        var audioDecoder: MediaCodec? = null
        var audioEncoder: MediaCodec? = null
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        var usedHw = false

        try {
            fun buildEncoderFmt(colorFormat: Int?): MediaFormat =
                MediaFormat.createVideoFormat(mime, outW, outH).apply {
                    setInteger(
                        MediaFormat.KEY_BIT_RATE,
                        resolveTargetBitrate(outW, outH, targetFps, opts.codec, rcMode, crf, abrKbps),
                    )
                    setInteger(MediaFormat.KEY_FRAME_RATE, targetFps.roundToInt().coerceAtLeast(1))
                    setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
                    if (colorFormat != null) setInteger(MediaFormat.KEY_COLOR_FORMAT, colorFormat)
                    if (Build.VERSION.SDK_INT >= 24 && colorFormat == null) {
                        try {
                            setInteger(
                                MediaFormat.KEY_BITRATE_MODE,
                                if (rcMode == "cq" || rcMode == "cq_value")
                                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CQ
                                else MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR,
                            )
                        } catch (_: Exception) { /* device lacks CQ — platform default stands */ }
                    }
                }

            // ---- encoder: HW preferred, transparent SW retry unless hardwareOnly ----
            var encCreated = false
            var lastErr: Exception? = null
            repeat(2) { attempt ->
                checkCancel(jobManager, jobId)
                if (!encCreated) {
                    try {
                        val enc = MediaCodec.createEncoderByType(mime)
                        val fmt = buildEncoderFmt(null) // null color ⇒ Surface mode
                        enc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                        val surface = enc.createInputSurface()
                        enc.start()
                        encoder = enc; encoderSurface = surface
                        usedHw = isHardwareCodec(enc.codecInfo)
                        if (!usedHw && requireHw) {
                            throw IllegalStateException("hardwareOnly requested but '$mime' encoder is software-only")
                        }
                        encCreated = true
                    } catch (e: Exception) {
                        lastErr = e
                        runCatching { encoder?.stop(); encoder?.release() }
                        runCatching { encoderSurface?.release() }
                        encoder = null; encoderSurface = null
                        if (requireHw) throw e
                    }
                }
            }
            if (!encCreated) throw lastErr ?: IllegalStateException("Failed to create video encoder")

            // ---- demuxers ----
            videoExtractor = MediaExtractor().apply { setDataSource(inputPath) }
            val vTrack = selectTrack(videoExtractor!!, "video/")
                ?: throw IllegalArgumentException("No video track in $inputPath")
            videoExtractor!!.selectTrack(vTrack)
            val decFmtIn = videoExtractor!!.getTrackFormat(vTrack)

            val audioSrcIdx = selectTrack(videoExtractor!!, "audio/")
            val wantAudio = audioMode != "remove" && audioSrcIdx != null
            var passthroughAudio = false
            var audioTranscodeReady = false
            var audioMuxTrack = -1
            var audioOutChannels = 0

            if (wantAudio) {
                audioExtractor = MediaExtractor().apply { setDataSource(inputPath) }
                audioExtractor!!.selectTrack(audioSrcIdx!!)
                val afmt = audioExtractor!!.getTrackFormat(audioSrcIdx)
                if (audioMode == "passthrough") {
                    passthroughAudio = true
                    // NOTE: muxer not created yet — track registered right after muxer construction.
                } else {
                    val srcCh = safeInt(afmt, MediaFormat.KEY_CHANNEL_COUNT, 2)
                    val srcSr = safeInt(afmt, MediaFormat.KEY_SAMPLE_RATE, 44100)
                    audioOutChannels = if (srcCh > 2) 2 else srcCh
                    val encFmt = MediaFormat.createAudioFormat("audio/mp4a-latm", srcSr, audioOutChannels).apply {
                        setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                        setInteger(MediaFormat.KEY_BIT_RATE, audioBrKbps * 1000)
                        setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 65536)
                    }
                    audioEncoder = MediaCodec.createEncoderByType("audio/mp4a-latm").also {
                        it.configure(encFmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE); it.start()
                    }
                    audioDecoder = MediaCodec.createDecoderByType(
                        afmt.getString(MediaFormat.KEY_MIME) ?: "audio/mp4a-latm",
                    ).also {
                        it.configure(afmt, null, null, 0); it.start()
                    }
                    audioTranscodeReady = true
                }
            }

            // ---- decoder: Surface zero-copy preferred, real ByteBuffer fallback ----
            val decMime = decFmtIn.getString(MediaFormat.KEY_MIME) ?: mime
            var surfaceMode = true
            var decoderCandidate: MediaCodec? = null
            val surfaceDecodeOk = try {
                decoderCandidate = MediaCodec.createDecoderByType(decMime)
                decoderCandidate!!.configure(decFmtIn, encoderSurface, null, 0)
                decoderCandidate!!.start()
                decoder = decoderCandidate
                true
            } catch (e: Exception) {
                // release the half-created decoder — no leak (audit P1-6)
                runCatching { decoderCandidate?.stop() }
                runCatching { decoderCandidate?.release() }
                decoderCandidate = null
                false
            }
            if (!surfaceDecodeOk) {
                // CPU path: decode YUV_420_888 → NV12 → encoder ByteBuffer input.
                surfaceMode = false
                runCatching { encoder?.stop(); encoder?.release() }
                runCatching { encoderSurface?.release() }
                encoder = null; encoderSurface = null
                encoder = MediaCodec.createEncoderByType(mime).also { e ->
                    e.configure(buildEncoderFmt(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible), null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                    e.start()
                }
                usedHw = isHardwareCodec(encoder!!.codecInfo)
                if (!usedHw && requireHw) {
                    throw IllegalStateException("hardwareOnly requested but CPU-path encoder is software-only")
                }
                decoder = MediaCodec.createDecoderByType(decMime).also { d ->
                    d.configure(decFmtIn, null, null, 0)
                    d.start()
                }
            }

            // ---- muxer ----
            val muxerFormat = when (effectiveContainer) {
                "webm" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM
                "3gp" -> MediaMuxer.OutputFormat.MUXER_OUTPUT_THREE_GPP
                else -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
            }
            muxer = MediaMuxer(tmpFile.absolutePath, muxerFormat)
            // Re-register passthrough audio track now (muxer instance created above).
            var pendingTracks = 1 + (if (passthroughAudio) 1 else 0)
            if (passthroughAudio) {
                audioMuxTrack = muxer.addTrack(audioExtractor!!.getTrackFormat(audioSrcIdx!!))
            }
            if (rotation != 0) runCatching { muxer.setOrientationHint(rotation) }

            var videoMuxTrack = -1
            fun maybeStartMuxer() {
                if (!muxerStarted && pendingTracks == 0) {
                    muxer.start()
                    muxerStarted = true
                }
            }

            // ---- interleaver state ----
            val videoQueue = ArrayDeque<PendingSample>()
            val audioQueue = ArrayDeque<PendingSample>()
            val queueCap = 64 // producers stall beyond this (codec buffers absorb pressure)

            var extractorDone = false
            var decoderDone = false
            var encoderDone = false
            var audioFeedDone = false
            var audioDecodeDone = false
            var audioEncodeDone = false
            var passthroughEos = !passthroughAudio

            var encodedFrames = 0L
            var lastPtsUs = 0L
            var lastVideoPtsUs = Long.MIN_VALUE
            var lastAudioPtsUs = Long.MIN_VALUE
            var lastProgressMs = 0L
            val timeoutUs = 1_000L // short per-call wait → fast cancellation (P2-4)
            val passBuf = ByteBuffer.allocateDirect(1 shl 17)

            // Per-lane stall watchdogs (P1-4): audio activity must never mask a
            // dead video lane (or vice versa). 30 s without lane progress ⇒ fail.
            val stallWindowMs = 30_000L
            var lastVideoActivityMs = System.currentTimeMillis()
            var lastAudioActivityMs = System.currentTimeMillis()
            fun noteVideoActivity() { lastVideoActivityMs = System.currentTimeMillis() }
            fun noteAudioActivity() { lastAudioActivityMs = System.currentTimeMillis() }

            // PTS gate — applied at DECODER OUTPUT (deterministic drop-only)
            var gateLastKeptUs = Long.MIN_VALUE
            val gateIntervalUs = (1_000_000.0 / targetFps.coerceAtLeast(1.0)).toLong()
            fun keepFrame(ptsUs: Long): Boolean {
                if (!limitFrameRate) return true
                if (gateLastKeptUs == Long.MIN_VALUE || ptsUs >= gateLastKeptUs + gateIntervalUs - gateIntervalUs / 4) {
                    gateLastKeptUs = ptsUs
                    return true
                }
                return false
            }

            val decInfo = MediaCodec.BufferInfo()
            val encInfo = MediaCodec.BufferInfo()
            val audDecInfo = MediaCodec.BufferInfo()
            val audEncInfo = MediaCodec.BufferInfo()

            // ---------------- multiplexed main loop ----------------
            while (true) {
                checkCancel(jobManager, jobId)
                val loopNow = System.currentTimeMillis()
                val videoLaneDone = encoderDone
                val audioLaneDone = !audioTranscodeReady || audioEncodeDone || passthroughEos
                if (!videoLaneDone && loopNow - lastVideoActivityMs > stallWindowMs) {
                    throw StallException("Video lane stalled: no encoder progress for 30s")
                }
                if (!audioLaneDone && loopNow - lastAudioActivityMs > stallWindowMs) {
                    throw StallException("Audio lane stalled: no progress for 30s")
                }

                val lanesFinished = encoderDone &&
                    (if (passthroughAudio) passthroughEos else !audioTranscodeReady || audioEncodeDone) &&
                    videoQueue.isEmpty() && audioQueue.isEmpty()
                if (lanesFinished) break

                // 1) feed video decoder
                if (!extractorDone) {
                    val idx = decoder!!.dequeueInputBuffer(timeoutUs)
                    if (idx >= 0) {
                        val buf = decoder!!.getInputBuffer(idx)!!
                        val size = videoExtractor!!.readSampleData(buf, 0)
                        if (size < 0) {
                            decoder!!.queueInputBuffer(idx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            extractorDone = true
                        } else {
                            decoder!!.queueInputBuffer(idx, 0, size, videoExtractor!!.sampleTime, 0)
                            videoExtractor!!.advance()
                            noteVideoActivity()
                        }
                    }
                }

                // 2) drain decoder — fps gate HERE on OUTPUT PTS
                if (!decoderDone) {
                    val outIdx = decoder!!.dequeueOutputBuffer(decInfo, timeoutUs)
                    if (outIdx >= 0) {
                        val eos = decInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        when {
                            eos -> {
                                decoderDone = true
                                decoder!!.releaseOutputBuffer(outIdx, false)
                                signalEncoderEos(encoder!!, surfaceMode, timeoutUs, jobManager, jobId)
                            }
                            decInfo.size > 0 && keepFrame(decInfo.presentationTimeUs) -> {
                                if (surfaceMode) {
                                    decoder!!.releaseOutputBuffer(outIdx, true) // renders into encoder surface
                                    noteVideoActivity()
                                } else {
                                    val img: Image? = decoder!!.getOutputImage(outIdx)
                                    if (img != null) {
                                        val nv12 = Yuv.toNv12(img)
                                        img.close()
                                        feedEncoderNv12(encoder!!, nv12, decInfo.presentationTimeUs, timeoutUs, jobManager, jobId)
                                        decoder!!.releaseOutputBuffer(outIdx, false)
                                        noteVideoActivity()
                                    } else {
                                        decoder!!.releaseOutputBuffer(outIdx, false)
                                    }
                                }
                            }
                            else -> decoder!!.releaseOutputBuffer(outIdx, false) // dropped by gate / empty
                        }
                    }
                }

                // 3) drain video encoder → queue (producer pauses when queue full ⇒ backpressure)
                if (!encoderDone && videoQueue.size < queueCap) {
                    val o = encoder!!.dequeueOutputBuffer(encInfo, timeoutUs)
                    when {
                        o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            if (videoMuxTrack == -1) {
                                videoMuxTrack = muxer.addTrack(encoder!!.outputFormat)
                                pendingTracks--
                                maybeStartMuxer()
                            }
                        }
                        o >= 0 -> {
                            val eos = encInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            val cfg = encInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                            if (cfg && videoMuxTrack == -1) {
                                videoMuxTrack = muxer.addTrack(encoder!!.outputFormat)
                                pendingTracks--
                                maybeStartMuxer()
                            }
                            if (!cfg && videoMuxTrack != -1 && muxerStarted && encInfo.size > 0) {
                                videoQueue.add(copySample(encoder!!.getOutputBuffer(o)!!, encInfo))
                                encodedFrames++
                                lastPtsUs = encInfo.presentationTimeUs
                                noteVideoActivity()
                            }
                            encoder!!.releaseOutputBuffer(o, false)
                            if (eos) encoderDone = true
                        }
                    }
                }

                // 4a) audio passthrough lane
                if (passthroughAudio && !passthroughEos && audioQueue.size < queueCap) {
                    passBuf.clear()
                    val size = audioExtractor!!.readSampleData(passBuf, 0)
                    if (size < 0) {
                        passthroughEos = true
                    } else {
                        audioQueue.add(pendingPassthrough(passBuf, size, audioExtractor!!.sampleTime, audioExtractor!!.sampleFlags))
                        audioExtractor!!.advance()
                        noteAudioActivity()
                    }
                }

                // 4b) audio transcode lane
                if (audioTranscodeReady && !audioEncodeDone) {
                    if (!audioFeedDone && audioQueue.size < queueCap) {
                        val idx = audioDecoder!!.dequeueInputBuffer(timeoutUs)
                        if (idx >= 0) {
                            val ib = audioDecoder!!.getInputBuffer(idx)!!
                            val size = audioExtractor!!.readSampleData(ib, 0)
                            if (size < 0) {
                                audioDecoder!!.queueInputBuffer(idx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                audioFeedDone = true
                            } else {
                                audioDecoder!!.queueInputBuffer(idx, 0, size, audioExtractor!!.sampleTime, 0)
                                audioExtractor!!.advance()
                            }
                        }
                    }
                    if (!audioDecodeDone) {
                        val o = audioDecoder!!.dequeueOutputBuffer(audDecInfo, timeoutUs)
                        if (o >= 0) {
                            val eos = audDecInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            if (eos) {
                                audioDecodeDone = true
                                audioDecoder!!.releaseOutputBuffer(o, false)
                                queueEosBounded(audioEncoder!!, timeoutUs, jobManager, jobId)
                            } else if (audDecInfo.size > 0) {
                                val pcm = audioDecoder!!.getOutputBuffer(o)!!.duplicate()
                                pcm.position(audDecInfo.offset).limit(audDecInfo.offset + audDecInfo.size)
                                val srcCh = safeInt(audioDecoder!!.outputFormat, MediaFormat.KEY_CHANNEL_COUNT, 2)
                                val mixed = Downmix.apply(pcm, srcCh, audioOutChannels)
                                audioDecoder!!.releaseOutputBuffer(o, false)
                                // Audit P0-2: NEVER drop a decoded PCM chunk because an
                                // encoder input buffer was momentarily unavailable —
                                // retry until fed or cancelled.
                                feedPcmRetry(audioEncoder!!, mixed, audDecInfo.presentationTimeUs, timeoutUs, jobManager, jobId)
                                noteAudioActivity()
                            } else audioDecoder!!.releaseOutputBuffer(o, false)
                        }
                    }
                    if (!audioEncodeDone && audioQueue.size < queueCap) {
                        val o = audioEncoder!!.dequeueOutputBuffer(audEncInfo, timeoutUs)
                        when {
                            o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                                if (audioMuxTrack == -1) {
                                    audioMuxTrack = muxer.addTrack(audioEncoder!!.outputFormat)
                                    pendingTracks--
                                    maybeStartMuxer()
                                }
                            }
                            o >= 0 -> {
                                val eos = audEncInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                                if (!eos && audioMuxTrack != -1 && muxerStarted && audEncInfo.size > 0) {
                                    audioQueue.add(copySample(audioEncoder!!.getOutputBuffer(o)!!, audEncInfo))
                                    noteAudioActivity()
                                }
                                audioEncoder!!.releaseOutputBuffer(o, false)
                                if (eos) audioEncodeDone = true
                            }
                        }
                    }
                }

                // 5) interleave write — smaller PTS first; consumer never blocked.
                // PTS safety (audit P1-2): clamp negative timestamps to 0 and
                // enforce per-track monotonicity so MediaMuxer never rejects the
                // stream (negative/non-monotonic sources are real-world files).
                if (muxerStarted) {
                    while (true) {
                        val vHead = videoQueue.peekFirst()
                        val aHead = audioQueue.peekFirst()
                        val pickVideo = when {
                            vHead == null -> false
                            aHead == null -> true
                            else -> vHead.info.presentationTimeUs <= aHead.info.presentationTimeUs
                        }
                        if (pickVideo) {
                            val raw = vHead.info.presentationTimeUs
                            val norm = if (raw < 0) 0 else raw
                            val safe = maxOf(norm, lastVideoPtsUs)
                            vHead.info.presentationTimeUs = safe
                            lastVideoPtsUs = safe
                            muxer.writeSampleData(videoMuxTrack, ByteBuffer.wrap(vHead.bytes), vHead.info)
                            videoQueue.pollFirst()
                        } else if (aHead != null) {
                            val raw = aHead.info.presentationTimeUs
                            val norm = if (raw < 0) 0 else raw
                            val safe = maxOf(norm, lastAudioPtsUs)
                            aHead.info.presentationTimeUs = safe
                            lastAudioPtsUs = safe
                            muxer.writeSampleData(audioMuxTrack, ByteBuffer.wrap(aHead.bytes), aHead.info)
                            audioQueue.pollFirst()
                        } else break
                    }
                }

                // 6) progress — real timestamps only (sync.c model), ≥120 ms cadence
                val now = System.currentTimeMillis()
                if (now - lastProgressMs > 120) {
                    lastProgressMs = now
                    val prog = when {
                        encodedFrames > 0 -> (encodedFrames.toDouble() / estTotalFrames).coerceIn(0.0, 1.0)
                        durationUs > 0 && lastPtsUs > 0 -> (lastPtsUs.toDouble() / durationUs).coerceIn(0.0, 1.0)
                        else -> 0.0
                    }
                    val fpsInst = if (now > startMs && encodedFrames > 0) (encodedFrames * 1000.0 / (now - startMs)) else 0.0
                    val remainMs = if (prog > 0.02 && prog < 1.0) (((now - startMs) / prog) - (now - startMs)).toLong() else null
                    onProgress(
                        linkedMapOf(
                            "progress" to prog,
                            "processedDurationMs" to (lastPtsUs / 1000).toInt(),
                            "totalDurationMs" to durationMs.toInt(),
                            "encodedFrames" to encodedFrames.toInt(),
                            "totalFrames" to estTotalFrames.toInt(),
                            "currentFps" to fpsInst,
                            "estimatedRemainingMs" to remainMs,
                            "stage" to "encode",
                            "state" to (jobManager.stateName(jobId) ?: "RUNNING"),
                        ),
                    )
                }
            }

            if (muxerStarted) muxer.stop()
        } catch (e: CancellationException) {
            runCatching { if (tmpFile.exists()) tmpFile.delete() }
            throw e
        } catch (e: Exception) {
            runCatching { if (tmpFile.exists()) tmpFile.delete() }
            throw e
        } finally {
            listOf(decoder, encoder, audioDecoder, audioEncoder).forEach { c ->
                runCatching { c?.stop() }
                runCatching { c?.release() }
            }
            runCatching { videoExtractor?.release() }
            runCatching { audioExtractor?.release() }
            runCatching { encoderSurface?.release() }
            runCatching { muxer?.release() }
        }

        // ---------------- validation ----------------
        if (!tmpFile.exists() || tmpFile.length() == 0L) {
            runCatching { tmpFile.delete() }
            throw OutputValidationException("Encoder produced empty output")
        }
        if (opts.keepOriginalIfSmaller && tmpFile.length() >= inFile.length()) {
            tmpFile.delete()
            return baseResult(inFile, inFile, startMs, usedHw, opts.codec, effectiveContainer, keptOriginal = true, notes)
        }

        if (outFile.exists()) outFile.delete()
        if (!tmpFile.renameTo(outFile)) {
            tmpFile.copyTo(outFile, overwrite = true)
            tmpFile.delete()
        }

        val outProbe = runCatching { MediaProbe.probe(outFile.absolutePath) }.getOrNull()
        if (outProbe == null) throw OutputValidationException("Post-encode probe failed — output unreadable")
        val outDur = outProbe["durationMs"] as Int
        if (durationMs > 500 && abs(outDur - durationMs) > maxOf(1500, durationMs / 4)) {
            throw OutputValidationException("Duration mismatch: expected ~${durationMs}ms got ${outDur}ms")
        }

        val outSize = outFile.length()
        val origSize = inFile.length()
        val saved = (origSize - outSize).coerceAtLeast(0)
        if (saved > 0 && origSize > 0 && saved * 100 / origSize < 5 && (probeInfo["overallBitrate"] as Int) in 1..1_500_000) {
            notes.add("Source appears already heavily compressed; recompression saved only ${"%.1f".format(saved * 100.0 / origSize)}%.")
        }
        baseResult(inFile, outFile, startMs, usedHw, opts.codec, effectiveContainer, keptOriginal = false, notes, outProbe)
    }

    // ------------------------------------------------------------ helpers

    internal data class PendingSample(val bytes: ByteArray, val info: MediaCodec.BufferInfo)

    private fun copySample(buf: ByteBuffer, info: MediaCodec.BufferInfo): PendingSample {
        val data = ByteArray(info.size)
        buf.duplicate().let { d ->
            d.position(info.offset).limit(info.offset + info.size)
            d.get(data)
        }
        return PendingSample(data, MediaCodec.BufferInfo().apply { set(0, info.size, info.presentationTimeUs, info.flags) })
    }

    private fun pendingPassthrough(buf: ByteBuffer, size: Int, ptsUs: Long, sampleFlags: Int): PendingSample {
        val data = ByteArray(size)
        buf.position(0).limit(size)
        buf.get(data)
        val flags = if (sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
        return PendingSample(data, MediaCodec.BufferInfo().apply { set(0, size, ptsUs, flags) })
    }

    private fun checkCancel(mgr: JobManager, jobId: String) {
        if (mgr.isCancelled(jobId)) throw CancellationException("Cancelled")
    }

    private fun selectTrack(extractor: MediaExtractor, prefix: String): Int? {
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            if ((f.getString(MediaFormat.KEY_MIME) ?: "").startsWith(prefix)) return i
        }
        return null
    }

    @Suppress("UNCHECKED_CAST")
    private fun probeVideoStreams(probe: Map<String, Any>): List<Map<String, Any>> =
        (probe["videoStreams"] as? List<Map<String, Any>>) ?: emptyList()

    private fun mimeFor(codec: String): String = when (codec.lowercase()) {
        "h265", "hevc" -> MediaFormat.MIMETYPE_VIDEO_HEVC
        "av1", "av01" -> "video/av01"
        "vp9" -> "video/x-vnd.on2.vp9"
        else -> MediaFormat.MIMETYPE_VIDEO_AVC
    }

    private fun resolveTargetBitrate(
        w: Int, h: Int, fps: Double, codec: String, rcMode: String, crf: Double?, abrKbps: Int?,
    ): Int {
        if (rcMode == "abr" && abrKbps != null) return (abrKbps * 1000).coerceIn(64_000, 40_000_000)
        val bpp = when {
            crf == null -> 0.07
            crf <= 19 -> 0.13
            crf <= 22 -> 0.10
            crf <= 26 -> 0.07
            crf <= 30 -> 0.045
            else -> 0.025
        }
        val factor = when (codec.lowercase()) { "h265", "hevc" -> 0.75; "av1" -> 0.70; "vp9" -> 0.78; else -> 1.0 }
        return (w * h * fps * bpp * factor).toInt().coerceIn(300_000, 20_000_000)
    }

    private fun isHardwareCodec(info: MediaCodecInfo?): Boolean {
        if (info == null) return false
        return if (Build.VERSION.SDK_INT >= 29) {
            runCatching { !info.isSoftwareOnly }.getOrDefault(!info.name.startsWith("OMX.google."))
        } else !info.name.startsWith("OMX.google.")
    }

    private fun signalEncoderEos(
        encoder: MediaCodec, surfaceMode: Boolean, timeoutUs: Long,
        mgr: JobManager, jobId: String,
    ) {
        if (surfaceMode) {
            runCatching { encoder.signalEndOfInputStream() }
        } else {
            queueEosBounded(encoder, timeoutUs, mgr, jobId)
        }
    }

    /**
     * Feed one NV12 frame to the byte-buffer encoder.
     * BOUNDED: cancellation-aware + 15 s stall deadline (P0-1) — a broken encoder
     * can no longer hang the job forever; it fails with [StallException].
     */
    private fun feedEncoderNv12(
        encoder: MediaCodec, nv12: ByteArray, ptsUs: Long, timeoutUs: Long,
        mgr: JobManager, jobId: String,
    ) {
        val deadlineMs = System.currentTimeMillis() + 15_000
        while (true) {
            checkCancel(mgr, jobId)
            if (System.currentTimeMillis() > deadlineMs) {
                throw StallException("Video encoder input stalled (no input buffer for 15s)")
            }
            val idx = encoder.dequeueInputBuffer(timeoutUs)
            if (idx >= 0) {
                val ib = encoder.getInputBuffer(idx)!!
                ib.clear()
                ib.put(nv12)
                encoder.queueInputBuffer(idx, 0, nv12.size, ptsUs, 0)
                return
            }
        }
    }

    /**
     * Retry PCM feed until delivered — cancellation-aware + 15 s stall deadline
     * (P0-2). Decoded PCM is NEVER dropped.
     */
    private fun feedPcmRetry(
        encoder: MediaCodec, pcm: ByteArray, ptsUs: Long, timeoutUs: Long,
        mgr: JobManager, jobId: String,
    ) {
        val deadlineMs = System.currentTimeMillis() + 15_000
        while (true) {
            checkCancel(mgr, jobId)
            if (System.currentTimeMillis() > deadlineMs) {
                throw StallException("Audio encoder input stalled (no input buffer for 15s)")
            }
            val idx = encoder.dequeueInputBuffer(timeoutUs)
            if (idx >= 0) {
                val eb = encoder.getInputBuffer(idx)!!
                eb.clear()
                eb.put(pcm)
                encoder.queueInputBuffer(idx, 0, pcm.size, ptsUs, 0)
                return
            }
        }
    }

    /**
     * Queue EOS on an encoder input — bounded retry so a lost EOS can never
     * strand a lane (P0-3/P0-4).
     */
    private fun queueEosBounded(encoder: MediaCodec, timeoutUs: Long, mgr: JobManager? = null, jobId: String? = null) {
        val deadlineMs = System.currentTimeMillis() + 15_000
        while (true) {
            if (mgr != null && jobId != null) checkCancel(mgr, jobId)
            if (System.currentTimeMillis() > deadlineMs) {
                throw StallException("Encoder EOS stalled (no input buffer for 15s)")
            }
            val idx = runCatching { encoder.dequeueInputBuffer(timeoutUs) }.getOrDefault(-1)
            if (idx >= 0) {
                encoder.queueInputBuffer(idx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                return
            }
        }
    }

    private fun safeInt(fmt: MediaFormat, key: String, def: Int): Int =
        runCatching { if (fmt.containsKey(key)) fmt.getInteger(key) else def }.getOrDefault(def)

    private fun baseResult(
        inFile: File,
        outFile: File,
        startMs: Long,
        usedHw: Boolean,
        codec: String,
        container: String,
        keptOriginal: Boolean,
        notes: MutableList<String>,
        outputProbe: Map<String, Any>? = null,
    ): Map<String, Any> {
        val outSize = outFile.length()
        val origSize = inFile.length()
        val saved = (origSize - outSize).coerceAtLeast(0)
        return linkedMapOf(
            "inputPath" to inFile.absolutePath,
            "outputPath" to outFile.absolutePath,
            "originalSizeBytes" to origSize,
            "outputSizeBytes" to outSize,
            "savedBytes" to saved,
            "compressionRatio" to if (outSize > 0) origSize.toDouble() / outSize else 1.0,
            "compressionPercentage" to if (origSize > 0) saved.toDouble() / origSize * 100 else 0.0,
            "durationMs" to (System.currentTimeMillis() - startMs).toInt(),
            "usedHardwareAcceleration" to usedHw,
            "codec" to codec,
            "container" to container,
            "outputMediaInfo" to outputProbe,
            "qualityWarning" to if (notes.isEmpty()) null else notes.joinToString(" "),
            "wasKeptOriginal" to keptOriginal,
        )
    }

    /** Legacy container sanity for pre-plan payloads (plan normally governs). */
    fun fallbackContainer(requested: String, codec: String): String =
        if (requested == "webm" && !codec.equals("vp9", true)) "mp4"
        else if (requested == "mov" || requested == "mkv") "mp4"
        else requested
}

/** YUV_420_888 Image → tightly-packed NV12 (fast paths; correct for both semi/planar layouts). */
internal object Yuv {
    fun toNv12(img: Image): ByteArray {
        require(img.format == android.graphics.ImageFormat.YUV_420_888)
        val w = img.width
        val h = img.height
        val yP = img.planes[0]
        val uP = img.planes[1]
        val vP = img.planes[2]

        val out = ByteArray(w * h * 3 / 2)
        var pos = 0

        // --- Y ---
        val yb = yP.buffer
        if (yP.pixelStride == 1 && yP.rowStride == w) {
            yb.position(0)
            yb.get(out, pos, w * h)
            pos += w * h
        } else {
            for (row in 0 until h) {
                val base = row * yP.rowStride
                if (yP.pixelStride == 1) {
                    yb.position(base)
                    yb.get(out, pos, w)
                    pos += w
                } else {
                    for (col in 0 until w) out[pos++] = yb.get(base + col * yP.pixelStride)
                }
            }
        }

        // --- Chroma ---
        val ch = h / 2
        val cw = w / 2
        when {
            uP.pixelStride == 2 -> {
                // Semi-planar: U plane rows are U0V0U1V1… (NV12 native layout).
                for (row in 0 until ch) {
                    val ub = uP.buffer.duplicate()
                    ub.position(row * uP.rowStride)
                    ub.get(out, pos, cw * 2)
                    pos += cw * 2
                }
            }
            else -> {
                // Planar: interleave U and V sample-by-sample.
                for (row in 0 until ch) {
                    val ub = uP.buffer
                    val vb = vP.buffer
                    val uBase = row * uP.rowStride
                    val vBase = row * vP.rowStride
                    for (col in 0 until cw) {
                        out[pos++] = ub.get(uBase + col * uP.pixelStride)
                        out[pos++] = vb.get(vBase + col * vP.pixelStride)
                    }
                }
            }
        }
        return out
    }
}

/** Channel downmix — documented approximation: >2ch→stereo takes FL/FR; stereo→mono averages. */
internal object Downmix {
    fun apply(src16LE: ByteBuffer, sourceChannels: Int, targetChannels: Int): ByteArray {
        require(targetChannels in 1..2)
        if (sourceChannels == targetChannels) {
            val arr = ByteArray(src16LE.remaining())
            src16LE.duplicate().get(arr)
            return arr
        }
        val dup = src16LE.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        val shorts = ShortArray(dup.remaining() / 2)
        dup.asShortBuffer().get(shorts)
        val frames = shorts.size / sourceChannels
        val out = ByteBuffer.allocate(frames * targetChannels * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (f in 0 until frames) {
            when {
                targetChannels == 1 -> {
                    var acc = 0
                    for (c in 0 until sourceChannels) acc += shorts[f * sourceChannels + c].toInt()
                    out.putShort((acc / sourceChannels).toShort())
                }
                else -> {
                    // stereo target: FL/FR from channels 0/1 (fallback duplicates ch0)
                    val l = shorts[f * sourceChannels]
                    val r = if (sourceChannels > 1) shorts[f * sourceChannels + 1] else l
                    out.putShort(l); out.putShort(r)
                }
            }
        }
        return out.array()
    }
}
