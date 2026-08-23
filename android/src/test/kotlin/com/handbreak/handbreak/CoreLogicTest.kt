package com.handbreak.handbreak

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** JVM tests for the pure-Kotlin channel downmix logic (no Android runtime needed). */
class DownmixTest {

    private fun s16(vararg samples: Short): ByteArray {
        val b = java.nio.ByteBuffer.allocate(samples.size * 2).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        samples.forEach(b::putShort)
        return b.array()
    }

    @Test
    fun `stereo to stereo is a pass-through copy`() {
        val src = s16(100, -100, 200, -200)
        val out = Downmix.apply(java.nio.ByteBuffer.wrap(src), 2, 2)
        assertTrue(src.contentEquals(out))
    }

    @Test
    fun `stereo to mono averages both channels`() {
        val src = s16(100, 300, -100, 100)
        val out = Downmix.apply(java.nio.ByteBuffer.wrap(src), 2, 1)
        val shorts = java.nio.ByteBuffer.wrap(out).order(java.nio.ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        assertEquals(200, shorts.get(0).toInt()) // (100+300)/2
        assertEquals(0, shorts.get(1).toInt())   // (-100+100)/2
        assertEquals(4, out.size) // 2 frames × 1 ch × 2 bytes
    }

    @Test
    fun `5ch to stereo keeps FL and FR`() {
        val src = s16(1000, 2000, 3000, 4000, 5000, 100, 200, 300, 400, 500)
        val out = Downmix.apply(java.nio.ByteBuffer.wrap(src), 5, 2)
        val shorts = java.nio.ByteBuffer.wrap(out).order(java.nio.ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        assertEquals(1000, shorts.get(0).toInt())
        assertEquals(2000, shorts.get(1).toInt())
        assertEquals(8, out.size) // 2 frames × 2 ch × 2 bytes
    }

    @Test
    fun `mono to stereo duplicates the single channel`() {
        val src = s16(777, -777)
        val out = Downmix.apply(java.nio.ByteBuffer.wrap(src), 1, 2)
        val shorts = java.nio.ByteBuffer.wrap(out).order(java.nio.ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        assertEquals(777, shorts.get(0).toInt())
        assertEquals(777, shorts.get(1).toInt())
        assertEquals(-777, shorts.get(2).toInt())
        assertEquals(-777, shorts.get(3).toInt())
    }
}

/** JVM tests for the pure-Kotlin resolution math. */
class ResolutionHelperTest {

    @Test
    fun `preserves aspect on maxWidth cap`() {
        val s = ResolutionHelper.calculate(3840, 2160, 1920, null, null, null, null)
        assertEquals(1920, s.width)
        assertEquals(1080, s.height)
    }

    @Test
    fun `portrait stays portrait`() {
        val s = ResolutionHelper.calculate(1080, 1920, 720, 720, null, null, null)
        assertTrue(s.height > s.width)
    }

    @Test
    fun `never upscales implicitly`() {
        val s = ResolutionHelper.calculate(640, 480, 1920, 1080, null, null, null)
        assertEquals(640, s.width)
        assertEquals(480, s.height)
    }

    @Test
    fun `scale halves dimensions`() {
        val s = ResolutionHelper.calculate(1920, 1080, null, null, null, null, 0.5)
        assertEquals(960, s.width)
        assertEquals(540, s.height)
    }

    @Test
    fun `modulus 2 always even`() {
        val s = ResolutionHelper.calculate(1921, 1081, 1920, null, null, null, null)
        assertEquals(0, s.width % 2)
        assertEquals(0, s.height % 2)
    }
}

/** JVM tests for the JobManager state machine + non-blocking submit. */
class JobManagerTest {

    @Test
    fun `submit does not block the caller`() {
        val mgr = JobManager(maxConcurrentJobs = 1)
        val j1 = mgr.createJob()
        val j2 = mgr.createJob()
        val gate = java.util.concurrent.CountDownLatch(1)

        // j1 occupies the single slot; j2 must queue without blocking the caller.
        val f1 = mgr.submit(j1) {
            gate.await(2, java.util.concurrent.TimeUnit.SECONDS)
            "done-1"
        }
        val startNanos = System.nanoTime()
        val f2 = mgr.submit(j2) { "done-2" }
        val elapsedMs = (System.nanoTime() - startNanos) / 1_000_000

        assertTrue("submit blocked the caller: ${elapsedMs}ms", elapsedMs < 500)
        gate.countDown()
        assertEquals("done-1", f1.get(5, java.util.concurrent.TimeUnit.SECONDS))
        assertEquals("done-2", f2.get(5, java.util.concurrent.TimeUnit.SECONDS))
        mgr.shutdown()
    }

    @Test
    fun `cancel is idempotent and observed by worker`() {
        val mgr = JobManager(maxConcurrentJobs = 1)
        val j = mgr.createJob()
        val result = java.util.concurrent.atomic.AtomicReference<String>()
        val started = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)

        val f = mgr.submit(j) {
            started.countDown()
            // Loop until cancel observed — cooperative cancellation contract.
            while (!mgr.isCancelled(j.id)) {
                try { Thread.sleep(5) } catch (_: InterruptedException) { break }
            }
            release.await(2, java.util.concurrent.TimeUnit.SECONDS)
            result.set("worker-saw-cancel")
            "cancelled-cleanly"
        }
        started.await(2, java.util.concurrent.TimeUnit.SECONDS)
        mgr.cancelJob(j.id)
        mgr.cancelJob(j.id) // idempotent — must not throw
        release.countDown()
        assertEquals("cancelled-cleanly", f.get(5, java.util.concurrent.TimeUnit.SECONDS))
        assertEquals("worker-saw-cancel", result.get())
        mgr.shutdown()
    }

    @Test
    fun `cancelAll covers every job`() {
        val mgr = JobManager(maxConcurrentJobs = 2)
        val jobs = (1..4).map { mgr.createJob() }
        jobs.forEach { mgr.submit(it) { Thread.sleep(50); "x" } }
        mgr.cancelAll()
        jobs.forEach { assertTrue(mgr.isCancelled(it.id)) }
        mgr.shutdown()
    }

    @Test
    fun `state machine rejects illegal transitions`() {
        val mgr = JobManager(maxConcurrentJobs = 1)
        val j = mgr.createJob()
        // CREATED → QUEUED (legal, via submit) then observe QUEUED.
        mgr.submit(j) { Thread.sleep(10); "ok" }
        // CREATED → QUEUED already consumed; direct COMPLETED is illegal and rejected.
        assertEquals("QUEUED", mgr.stateName(j.id))
        mgr.shutdown()
    }

    @Test
    fun `bounded queue rejects excess jobs without blocking the caller`() {
        val mgr = JobManager(maxConcurrentJobs = 1)
        val gate = java.util.concurrent.CountDownLatch(1)
        val jobs = (1..JobManager.MAX_QUEUED_JOBS).map { mgr.createJob() }
        // Occupy the single worker so everything queues (1 running + 7 queued = 8).
        val first = mgr.submit(jobs[0]) { gate.await(5, java.util.concurrent.TimeUnit.SECONDS); "x" }
        jobs.drop(1).forEach { mgr.submit(it) { "y" } }
        // The (MAX_QUEUED_JOBS+1)th job must be rejected synchronously.
        val overflow = mgr.createJob()
        val startNanos = System.nanoTime()
        try {
            mgr.submit(overflow) { "z" }
            assertTrue("overflow job should have been rejected", false)
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("Too many queued"))
        }
        val elapsedMs = (System.nanoTime() - startNanos) / 1_000_000
        assertTrue("rejection blocked the caller: ${elapsedMs}ms", elapsedMs < 500)
        gate.countDown()
        assertEquals("x", first.get(5, java.util.concurrent.TimeUnit.SECONDS))
        mgr.shutdown()
    }

    @Test
    fun `cancelled queued job never executes its body`() {
        val mgr = JobManager(maxConcurrentJobs = 1)
        val gate = java.util.concurrent.CountDownLatch(1)
        val ran = java.util.concurrent.atomic.AtomicBoolean(false)
        val blocker = mgr.submit(mgr.createJob()) { gate.await(5, java.util.concurrent.TimeUnit.SECONDS); "b" }
        val queued = mgr.createJob()
        val queuedFuture = mgr.submit(queued) { ran.set(true); "q" }
        mgr.cancelJob(queued.id) // cancel BEFORE execution begins
        gate.countDown()
        assertEquals("b", blocker.get(5, java.util.concurrent.TimeUnit.SECONDS))
        assertFalse("cancelled queued job body must not run", ran.get())
        try {
            queuedFuture.get(5, java.util.concurrent.TimeUnit.SECONDS)
            assertTrue("expected cancellation failure", false)
        } catch (e: java.util.concurrent.ExecutionException) {
            // task threw CancellationException → wrapped in ExecutionException
            assertTrue(e.cause is java.util.concurrent.CancellationException)
        }
        mgr.shutdown()
    }

    @Test
    fun `removeJob is idempotent`() {
        val mgr = JobManager(maxConcurrentJobs = 1)
        val j = mgr.createJob()
        mgr.removeJob(j.id)
        mgr.removeJob(j.id) // second call must not throw
        assertFalse(mgr.isCancelled(j.id))
        mgr.shutdown()
    }
}