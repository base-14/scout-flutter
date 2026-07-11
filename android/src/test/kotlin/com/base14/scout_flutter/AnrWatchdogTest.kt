package com.base14.scout_flutter

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * JVM tests for [AnrWatchdog] using an injected poster that simulates the
 * Android main thread: posted runnables execute promptly unless the
 * simulated main thread is "blocked".
 *
 * Timings use a small threshold (200ms) with generous assertions to stay
 * robust on slow CI machines.
 */
class AnrWatchdogTest {
    private val queue = ConcurrentLinkedQueue<Runnable>()

    @Volatile private var mainRunning = true
    @Volatile private var blockedUntil = 0L
    private lateinit var mainSim: Thread
    private var watchdog: AnrWatchdog? = null

    @Before
    fun setUp() {
        mainRunning = true
        blockedUntil = 0L
        mainSim = Thread {
            while (mainRunning) {
                val now = System.currentTimeMillis()
                if (now < blockedUntil) {
                    Thread.sleep(5)
                    continue
                }
                val r = queue.poll()
                if (r == null) {
                    Thread.sleep(2)
                } else {
                    r.run()
                }
            }
        }
        mainSim.start()
    }

    @After
    fun tearDown() {
        watchdog?.stop()
        mainRunning = false
        mainSim.join(1000)
    }

    private fun startWatchdog(
        thresholdMs: Long,
        onAnr: (Long) -> Unit,
    ) {
        watchdog = AnrWatchdog(
            thresholdMs = thresholdMs,
            onAnrDetected = onAnr,
            poster = { r -> queue.add(r) },
            tickMs = 10L,
            idleGapMs = 10L,
        )
        watchdog!!.start()
    }

    /** Block the simulated main thread for [ms] from now. */
    private fun blockMainFor(ms: Long) {
        blockedUntil = System.currentTimeMillis() + ms
    }

    @Test
    fun detectsHangThatStartsMidCycle() {
        val latch = CountDownLatch(1)
        startWatchdog(200) { latch.countDown() }

        // Let the watchdog run a few healthy ping cycles first, so the
        // hang begins mid-cycle (the phase that the old single-sleep
        // implementation missed ~80% of the time).
        Thread.sleep(150)
        blockMainFor(600) // 3x threshold

        assertTrue(
            "hang starting mid-cycle must be detected",
            latch.await(2, TimeUnit.SECONDS),
        )
    }

    @Test
    fun firesExactlyOncePerSustainedHang() {
        val count = AtomicInteger(0)
        startWatchdog(200) { count.incrementAndGet() }

        Thread.sleep(100)
        blockMainFor(1000) // 5x threshold — old code fired repeatedly here
        Thread.sleep(1400)

        assertEquals("one hang must produce exactly one detection", 1, count.get())
    }

    @Test
    fun reArmsAfterMainThreadRecovers() {
        val count = AtomicInteger(0)
        startWatchdog(200) { count.incrementAndGet() }

        Thread.sleep(100)
        blockMainFor(500)
        Thread.sleep(800) // hang + recovery window
        blockMainFor(500)
        Thread.sleep(800)

        assertEquals("two separate hangs must produce two detections", 2, count.get())
    }

    @Test
    fun ignoresHangsShorterThanThreshold() {
        val count = AtomicInteger(0)
        startWatchdog(400) { count.incrementAndGet() }

        repeat(3) {
            Thread.sleep(100)
            blockMainFor(150) // well under threshold
            Thread.sleep(250)
        }

        assertEquals("short blocks must not fire", 0, count.get())
    }

    @Test
    fun reportsPendingDurationOfAtLeastThreshold() {
        val reported = AtomicLong(0)
        val latch = CountDownLatch(1)
        startWatchdog(200) { duration ->
            reported.set(duration)
            latch.countDown()
        }

        Thread.sleep(80)
        blockMainFor(600)

        assertTrue(latch.await(2, TimeUnit.SECONDS))
        assertTrue(
            "reported duration (${reported.get()}) must be >= threshold",
            reported.get() >= 200,
        )
    }
}
