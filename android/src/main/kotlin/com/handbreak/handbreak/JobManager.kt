package com.handbreak.handbreak

import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Formal job states — transitions validated, terminal exactly-once. */
enum class JobState {
    CREATED,
    QUEUED,
    PROBING,
    PLANNING,
    INITIALIZING,
    RUNNING,
    DRAINING,
    VALIDATING,
    COMMITTING,
    COMPLETED,
    /** Cancellation requested; worker is still cleaning up. */
    CANCELLING,
    CANCELLED,
    FAILED,
    DISPOSED,
}

/**
 * Bounded job executor.
 *
 * Capacity is STRUCTURAL, not counted (🔴-3):
 *   ThreadPoolExecutor(core=1, max=1, queue=ArrayBlockingQueue(MAX_QUEUED_JOBS))
 * The executor itself is the bounded queue; admission beyond it is rejected
 * synchronously with a QUEUE_FULL error. No semaphore, no soft counters.
 *
 * Cancellation semantics (🔴-4):
 * - [cancelJob] sets the flag and moves to CANCELLING (requested, not yet
 *   terminal). The worker observes the flag, cleans up, and the plugin then
 *   calls [markCancelled] for the terminal CANCELLED state.
 * - Queued jobs that never started transition directly to CANCELLED.
 * - All transitions are validated; terminal states are exactly-once.
 */
class JobManager(private val maxConcurrentJobs: Int = 1) {

    companion object { const val MAX_QUEUED_JOBS = 8 }

    data class Job(
        val id: String = UUID.randomUUID().toString(),
        val cancelFlag: AtomicBoolean = AtomicBoolean(false),
        val state: AtomicReference<JobState> = AtomicReference(JobState.CREATED),
        @Volatile var progressSink: ((Map<String, Any?>) -> Unit)? = null,
        var tempOutputPath: String? = null,
    )

    private val executor = ThreadPoolExecutor(
        maxConcurrentJobs.coerceAtLeast(1),
        maxConcurrentJobs.coerceAtLeast(1),
        0L,
        TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(MAX_QUEUED_JOBS),
        ThreadPoolExecutor.AbortPolicy(),
    )
    private val jobs = ConcurrentHashMap<String, Job>()

    fun createJob(): Job {
        val j = Job()
        jobs[j.id] = j
        return j
    }

    fun getJob(id: String): Job? = jobs[id]

    fun cancelJob(id: String) {
        val j = jobs[id] ?: return
        j.cancelFlag.set(true)
        // 🔴-4: CANCELLING = requested; terminal CANCELLED happens in the worker
        // (markCancelled) or immediately for never-started queued jobs.
        transition(j, JobState.CANCELLING, allowFrom = activeStates)
    }

    fun cancelAll() {
        val ids = jobs.keys.toList()
        ids.forEach(::cancelJob)
    }

    fun removeJob(id: String) {
        val j = jobs.remove(id)
        j?.let { transition(it, JobState.DISPOSED, allowFrom = JobState.entries.toSet()) }
    }

    fun <T> submit(job: Job, block: () -> T): java.util.concurrent.Future<T> {
        // Never blocks the caller: the bounded executor queue absorbs up to
        // MAX_QUEUED_JOBS waiters; overflow is rejected synchronously.
        transition(job, JobState.QUEUED, allowFrom = setOf(JobState.CREATED))
        return try {
            executor.submit<T> {
                if (job.cancelFlag.get()) {
                    transition(job, JobState.CANCELLED, allowFrom = setOf(JobState.QUEUED, JobState.CANCELLING))
                    throw java.util.concurrent.CancellationException("Cancelled before start")
                }
                block()
            }
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            transition(job, JobState.FAILED, allowFrom = setOf(JobState.QUEUED))
            throw IllegalStateException("Too many queued jobs (max $MAX_QUEUED_JOBS)")
        }
    }

    fun markRunning(jobId: String) =
        transition(jobs[jobId], JobState.RUNNING, allowFrom = setOf(JobState.QUEUED, JobState.INITIALIZING, JobState.PROBING, JobState.CANCELLING))

    fun markCancelled(jobId: String) {
        val j = jobs[jobId] ?: return
        j.cancelFlag.set(true)
        transition(j, JobState.CANCELLED, allowFrom = JobState.entries.toSet())
    }

    fun markFailed(jobId: String) {
        transition(jobs[jobId], JobState.FAILED, allowFrom = JobState.entries.toSet())
    }

    fun isCancelled(jobId: String): Boolean = jobs[jobId]?.cancelFlag?.get() == true

    fun stateName(jobId: String): String? = jobs[jobId]?.state?.get()?.name

    fun emitProgress(jobId: String, progress: Map<String, Any?>) {
        jobs[jobId]?.progressSink?.invoke(progress)
    }

    fun shutdown() {
        cancelAll()
        executor.shutdown()
    }

    private val activeStates = setOf(
        JobState.CREATED, JobState.QUEUED, JobState.PROBING, JobState.PLANNING,
        JobState.INITIALIZING, JobState.RUNNING, JobState.DRAINING,
        JobState.VALIDATING, JobState.COMMITTING,
    )

    private fun transition(job: Job?, target: JobState, allowFrom: Set<JobState>) {
        if (job == null) return
        while (true) {
            val cur = job.state.get()
            if (cur in allowFrom) {
                if (job.state.compareAndSet(cur, target)) return
            } else {
                return // illegal transition — reject silently (idempotent guards)
            }
        }
    }
}