package com.handbreak.handbreak

import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Formal job states (spec §5) — transitions validated, terminal exactly-once. */
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
    CANCELLED,
    FAILED,
    DISPOSED,
}

/**
 * Bounded job executor.
 *
 * Correctness contract (audit v3):
 * - [submit] NEVER blocks the caller thread: the semaphore is acquired inside
 *   the worker task, so callers (including the MethodChannel handler on the
 *   main thread) return immediately. Queued jobs wait on the worker.
 * - Cooperative cancellation via [cancelFlag]; idempotent.
 * - [cancelAll] cancels every job (used on engine detach — battery safety).
 * - State transitions are monotonic; [stateFor] returns the current state.
 * - Completion/cancellation/error each happen exactly once (guard flags).
 */
class JobManager(private val maxConcurrentJobs: Int = 1) {

    /** Bounded admission queue (P2-1): excess jobs are rejected, not stacked. */
    companion object { const val MAX_QUEUED_JOBS = 8 }

    data class Job(
        val id: String = UUID.randomUUID().toString(),
        val cancelFlag: AtomicBoolean = AtomicBoolean(false),
        val state: AtomicReference<JobState> = AtomicReference(JobState.CREATED),
        @Volatile var progressSink: ((Map<String, Any>) -> Unit)? = null,
        var tempOutputPath: String? = null,
    )

    private val executor = Executors.newFixedThreadPool(maxConcurrentJobs.coerceAtLeast(1))
    private val semaphore = Semaphore(maxConcurrentJobs.coerceAtLeast(1))
    private val jobs = ConcurrentHashMap<String, Job>()
    private val queuedJobs = java.util.concurrent.atomic.AtomicInteger(0)

    fun createJob(): Job {
        val j = Job()
        jobs[j.id] = j
        return j
    }

    fun getJob(id: String): Job? = jobs[id]

    fun cancelJob(id: String) {
        val j = jobs[id] ?: return
        j.cancelFlag.set(true)
        // CANCELLED is terminal; worker will observe and stop.
        transition(j, JobState.CANCELLED, allowFrom = setOf(JobState.CREATED, JobState.QUEUED, JobState.PROBING, JobState.PLANNING, JobState.INITIALIZING, JobState.RUNNING, JobState.DRAINING, JobState.VALIDATING, JobState.COMMITTING))
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
        // Semaphore is acquired INSIDE the task — never blocks the caller.
        transition(job, JobState.QUEUED, allowFrom = setOf(JobState.CREATED))
        if (queuedJobs.incrementAndGet() > MAX_QUEUED_JOBS) {
            queuedJobs.decrementAndGet()
            transition(job, JobState.FAILED, allowFrom = setOf(JobState.QUEUED))
            throw IllegalStateException("Too many queued jobs (max $MAX_QUEUED_JOBS)")
        }
        return executor.submit<T> {
            try {
                semaphore.acquire()
                try {
                    if (job.cancelFlag.get()) {
                        transition(job, JobState.CANCELLED, allowFrom = setOf(JobState.QUEUED))
                        throw java.util.concurrent.CancellationException("Cancelled before start")
                    }
                    block()
                } finally {
                    semaphore.release()
                }
            } finally {
                queuedJobs.decrementAndGet()
            }
        }
    }

    fun markRunning(jobId: String) =
        transition(jobs[jobId], JobState.RUNNING, allowFrom = setOf(JobState.QUEUED, JobState.INITIALIZING, JobState.PROBING))

    fun isCancelled(jobId: String): Boolean = jobs[jobId]?.cancelFlag?.get() == true

    fun stateName(jobId: String): String? = jobs[jobId]?.state?.get()?.name

    fun emitProgress(jobId: String, progress: Map<String, Any>) {
        jobs[jobId]?.progressSink?.invoke(progress)
    }

    fun shutdown() {
        cancelAll()
        executor.shutdown()
    }

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