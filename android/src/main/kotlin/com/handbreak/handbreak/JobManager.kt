package com.handbreak.handbreak

import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Mirrors HandBrake's job lifecycle (HB_STATE_WORKING → done/error) with a bounded executor.
 * Default maxConcurrentJobs = 1 on mobile to respect battery/RAM/thermals.
 * Extra jobs queue via Semaphore — callers block on start() until a slot frees.
 *
 * Each Job owns: cancel flag, progress callback, temp-file tracking.
 */
class JobManager(private val maxConcurrentJobs: Int = 1) {

    data class Job(
        val id: String = UUID.randomUUID().toString(),
        val cancelFlag: AtomicBoolean = AtomicBoolean(false),
        var progressSink: ((Map<String, Any>) -> Unit)? = null,
        var tempOutputPath: String? = null,
    )

    private val executor = Executors.newFixedThreadPool(maxConcurrentJobs.coerceAtLeast(1))
    private val semaphore = Semaphore(maxConcurrentJobs.coerceAtLeast(1))
    private val jobs = ConcurrentHashMap<String, Job>()

    fun createJob(): Job {
        val j = Job()
        jobs[j.id] = j
        return j
    }

    fun getJob(id: String): Job? = jobs[id]

    fun cancelJob(id: String) {
        jobs[id]?.cancelFlag?.set(true)
    }

    fun removeJob(id: String) { jobs.remove(id) }

    fun <T> submit(job: Job, block: () -> T): java.util.concurrent.Future<T> {
        semaphore.acquire()
        return executor.submit<T> {
            try { block() } finally { semaphore.release() }
        }
    }

    fun isCancelled(jobId: String): Boolean = jobs[jobId]?.cancelFlag?.get() == true

    fun emitProgress(jobId: String, progress: Map<String, Any>) {
        jobs[jobId]?.progressSink?.invoke(progress)
    }

    fun shutdown() { executor.shutdown() }
}
