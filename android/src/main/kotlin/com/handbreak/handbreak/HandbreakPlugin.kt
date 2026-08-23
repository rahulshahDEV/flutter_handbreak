package com.handbreak.handbreak

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap

/**
 * Plugin registration + MethodChannel dispatch.
 *
 * Mirrors HandBrake's job lifecycle: each `start*Compression` creates a Job with a tmp file,
 * runs on JobManager's bounded executor, streams progress via per-job EventChannel, and
 * validates output before completing. Cancellation is idempotent and deletes partial files.
 *
 * Large media never crosses the channel — only paths + option maps + progress ticks.
 */
class HandbreakPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var methodChannel: MethodChannel
    private var flutterPluginBinding: FlutterPlugin.FlutterPluginBinding? = null

    // One EventChannel per job (handbreak/progress/<jobId>) — created lazily.
    private val eventChannels = ConcurrentHashMap<String, EventChannel>()
    private val eventSinks = ConcurrentHashMap<String, EventChannel.EventSink>()
    private val jobManager = JobManager(maxConcurrentJobs = 1)
    // jobId → future for waitForResult
    private val jobFutures = ConcurrentHashMap<String, java.util.concurrent.Future<Map<String, Any>>>()
    private val jobResults = ConcurrentHashMap<String, Map<String, Any>>()
    private val jobErrors = ConcurrentHashMap<String, Map<String, Any>>()

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        flutterPluginBinding = binding
        methodChannel = MethodChannel(binding.binaryMessenger, "handbreak")
        methodChannel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        jobManager.shutdown()
        flutterPluginBinding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getHardwareCapabilities" -> {
                try { result.success(HardwareCapabilitiesProvider.get()) }
                catch (e: Exception) { result.error("ENCODING_ERROR", e.message, null) }
            }
            "probe" -> {
                val inputPath = call.argument<String>("inputPath")
                    ?: return result.error("INVALID_INPUT", "inputPath required", null)
                try {
                    // probe is fast; run inline
                    val info = MediaProbe.probe(inputPath)
                    result.success(info)
                } catch (e: IllegalArgumentException) {
                    result.error("INVALID_INPUT", e.message, null)
                } catch (e: Exception) {
                    result.error("UNSUPPORTED_FORMAT", e.message, null)
                }
            }
            "startVideoCompression" -> handleStartVideo(call, result)
            "startImageCompression" -> handleStartImage(call, result)
            "waitForResult" -> {
                val jobId = call.argument<String>("jobId")
                    ?: return result.error("INVALID_INPUT", "jobId required", null)
                // If already completed, return immediately; else block (but on bg thread via handler? For plugin we must not ANR — use async)
                val cached = jobResults[jobId]
                if (cached != null) { result.success(cached); return }
                val err = jobErrors[jobId]
                if (err != null) { result.success(mapOf("error" to err)); return }
                // For waitForResult we support polling + async: launch a small thread that blocks on future
                Thread {
                    try {
                        val fut = jobFutures[jobId]
                            ?: return@Thread mainHandler.post { result.error("INVALID_INPUT", "Unknown jobId $jobId", null) }
                        val res = fut.get() // blocks until transcode finishes
                        // future completed via jobResults population below; just return
                        mainHandler.post { result.success(res) }
                    } catch (e: java.util.concurrent.CancellationException) {
                        mainHandler.post { result.success(mapOf("error" to mapOf("code" to "CANCELLED", "message" to "Cancelled"))) }
                    } catch (e: java.util.concurrent.ExecutionException) {
                        val cause = e.cause
                        val errMap = mapOf("code" to mapErrorCode(cause), "message" to (cause?.message ?: "Unknown error"))
                        mainHandler.post { result.success(mapOf("error" to errMap)) }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("ENCODING_ERROR", e.message, null) }
                    }
                }.start()
            }
            "cancelJob" -> {
                val jobId = call.argument<String>("jobId")
                    ?: return result.error("INVALID_INPUT", "jobId required", null)
                jobManager.cancelJob(jobId)
                // Also cancel future if possible
                try { jobFutures[jobId]?.cancel(true) } catch (_: Exception) {}
                result.success(null)
            }
            "disposeJob" -> {
                val jobId = call.argument<String>("jobId")
                if (jobId != null) {
                    eventChannels.remove(jobId)?.setStreamHandler(null)
                    eventSinks.remove(jobId)
                    jobResults.remove(jobId)
                    jobErrors.remove(jobId)
                    jobFutures.remove(jobId)
                    jobManager.removeJob(jobId)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleStartVideo(call: MethodCall, result: MethodChannel.Result) {
        val inputPath = call.argument<String>("inputPath")
            ?: return result.error("INVALID_INPUT", "inputPath required", null)
        val outputPath = call.argument<String>("outputPath")
            ?: return result.error("INVALID_INPUT", "outputPath required", null)
        @Suppress("UNCHECKED_CAST")
        val options = call.argument<Map<String, Any>>("options") ?: emptyMap()

        val job = jobManager.createJob()
        // register per-job EventChannel for progress
        registerProgressChannel(job.id)

        val future = jobManager.submit(job) {
            try {
                val res = VideoTranscoder.transcode(
                    inputPath = inputPath, outputPath = outputPath, optsRaw = options,
                    jobId = job.id, jobManager = jobManager
                ) { prog ->
                    postProgress(job.id, prog)
                }
                jobResults[job.id] = res
                // final progress 1.0
                postProgress(job.id, mapOf("progress" to 1.0, "processedDurationMs" to 0, "totalDurationMs" to 0,
                    "encodedFrames" to 0, "totalFrames" to 0, "currentFps" to 0.0, "stage" to "done"))
                closeProgress(job.id)
                res
            } catch (e: VideoTranscoder.CancellationException) {
                val err = mapOf("code" to "CANCELLED", "message" to "Cancelled")
                jobErrors[job.id] = err
                postProgress(job.id, mapOf("error" to err))
                closeProgress(job.id)
                throw java.util.concurrent.CancellationException("Cancelled")
            } catch (e: IllegalArgumentException) {
                val err = mapOf("code" to "INVALID_INPUT", "message" to (e.message ?: "Invalid input"))
                jobErrors[job.id] = err
                postProgress(job.id, mapOf("error" to err))
                closeProgress(job.id)
                throw e
            } catch (e: IllegalStateException) {
                val code = if (e.message?.contains("Hardware", true) == true) "HARDWARE_UNAVAILABLE" else "ENCODING_ERROR"
                val err = mapOf("code" to code, "message" to (e.message ?: "Encoding failed"))
                jobErrors[job.id] = err
                postProgress(job.id, mapOf("error" to err))
                closeProgress(job.id)
                throw e
            } catch (e: Exception) {
                val err = mapOf("code" to "ENCODING_ERROR", "message" to (e.message ?: "Unknown"))
                jobErrors[job.id] = err
                postProgress(job.id, mapOf("error" to err))
                closeProgress(job.id)
                throw e
            }
        }
        jobFutures[job.id] = future
        result.success(job.id)
    }

    private fun handleStartImage(call: MethodCall, result: MethodChannel.Result) {
        val inputPath = call.argument<String>("inputPath")
            ?: return result.error("INVALID_INPUT", "inputPath required", null)
        val outputPath = call.argument<String>("outputPath")
            ?: return result.error("INVALID_INPUT", "outputPath required", null)
        @Suppress("UNCHECKED_CAST")
        val options = call.argument<Map<String, Any>>("options") ?: emptyMap()
        val job = jobManager.createJob()
        registerProgressChannel(job.id)
        val opts = parseImageOptions(options)
        val future = jobManager.submit(job) {
            try {
                val res = ImageTranscoder.compress(inputPath, outputPath, opts, job.id, jobManager) { prog -> postProgress(job.id, prog) }
                jobResults[job.id] = res
                closeProgress(job.id)
                res
            } catch (e: VideoTranscoder.CancellationException) {
                val err = mapOf("code" to "CANCELLED", "message" to "Cancelled")
                jobErrors[job.id] = err; postProgress(job.id, mapOf("error" to err)); closeProgress(job.id)
                throw java.util.concurrent.CancellationException("Cancelled")
            } catch (e: Exception) {
                val err = mapOf("code" to mapErrorCode(e), "message" to (e.message ?: "Unknown"))
                jobErrors[job.id] = err; postProgress(job.id, mapOf("error" to err)); closeProgress(job.id)
                throw e
            }
        }
        jobFutures[job.id] = future
        result.success(job.id)
    }

    private fun registerProgressChannel(jobId: String) {
        val binding = flutterPluginBinding ?: return
        val channel = EventChannel(binding.binaryMessenger, "handbreak/progress/$jobId")
        eventChannels[jobId] = channel
        channel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                eventSinks[jobId] = sink
                // tie sink to jobManager so VideoTranscoder can emit via it
                jobManager.getJob(jobId)?.progressSink = { prog ->
                    mainHandler.post { try { sink.success(prog) } catch (_: Exception) {} }
                }
            }
            override fun onCancel(args: Any?) {
                eventSinks.remove(jobId)
                jobManager.getJob(jobId)?.progressSink = null
            }
        })
    }

    private fun postProgress(jobId: String, prog: Map<String, Any>) {
        val sink = eventSinks[jobId] ?: return
        mainHandler.post { try { sink.success(prog) } catch (_: Exception) {} }
    }

    private fun closeProgress(jobId: String) {
        val sink = eventSinks[jobId] ?: return
        mainHandler.post { try { sink.endOfStream() } catch (_: Exception) {} }
    }

    private fun parseImageOptions(m: Map<String, Any>): ImageTranscoder.Options {
        return ImageTranscoder.Options(
            quality = (m["quality"] as? Number)?.toInt() ?: 82,
            maxWidth = (m["maxWidth"] as? Number)?.toInt(),
            maxHeight = (m["maxHeight"] as? Number)?.toInt(),
            format = (m["format"] as? String) ?: "auto",
            preserveExif = m["preserveExif"] as? Boolean ?: false,
            preserveAlpha = m["preserveAlpha"] as? Boolean ?: true,
            progressive = m["progressive"] as? Boolean ?: false,
            keepOriginalIfSmaller = m["keepOriginalIfSmaller"] as? Boolean ?: true
        )
    }

    private fun mapErrorCode(e: Throwable?): String = when (e) {
        is IllegalArgumentException -> "INVALID_INPUT"
        is IllegalStateException -> if (e.message?.contains("Hardware", true) == true) "HARDWARE_UNAVAILABLE" else "ENCODING_ERROR"
        is java.util.concurrent.CancellationException -> "CANCELLED"
        else -> "ENCODING_ERROR"
    }
}
