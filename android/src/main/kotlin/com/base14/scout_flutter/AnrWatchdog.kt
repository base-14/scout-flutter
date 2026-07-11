package com.base14.scout_flutter

import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Detects main-thread hangs by posting a ping to the main looper and
 * measuring how long it stays unanswered.
 *
 * The watchdog thread polls every [tickMs] while a ping is pending, so a
 * hang is detected as soon as the pending time reaches [thresholdMs] —
 * regardless of where in the ping cycle the hang started. (A previous
 * implementation slept for the full threshold between ping and check,
 * which made detection phase-dependent: a hang of threshold+X ms was only
 * caught if the ping happened to land inside the hang — ~X/threshold odds.)
 *
 * Fires [onAnrDetected] once per hang, from the watchdog thread while the
 * main thread is still wedged (so callers can capture a live thread dump),
 * and re-arms only after the main thread answers the ping (recovery).
 *
 * [poster] is injectable for JVM tests; production uses the main looper.
 */
class AnrWatchdog(
    private val thresholdMs: Long,
    private val onAnrDetected: (Long) -> Unit,
    poster: ((Runnable) -> Unit)? = null,
    private val tickMs: Long = 100L,
    private val idleGapMs: Long = 500L,
) {
    private var watchdogThread: Thread? = null
    @Volatile private var running = false

    private val poster: (Runnable) -> Unit =
        poster ?: { r -> Handler(Looper.getMainLooper()).post(r) }

    fun start() {
        if (running) return
        running = true
        watchdogThread = Thread({
            while (running) {
                val responded = AtomicBoolean(false)
                val postedAtNs = System.nanoTime()
                poster { responded.set(true) }

                var fired = false
                // Poll while the ping is unanswered; fire once when the
                // pending time crosses the threshold. The cycle (and thus
                // the hang scope) ends only when the ping is answered.
                while (running && !responded.get()) {
                    if (!sleepQuietly(tickMs)) return@Thread
                    if (fired || responded.get()) continue
                    val pendingMs = (System.nanoTime() - postedAtNs) / 1_000_000
                    if (pendingMs >= thresholdMs) {
                        fired = true
                        onAnrDetected(pendingMs)
                    }
                }

                // Ping answered → main thread recovered → re-armed by the
                // next cycle. The idle gap bounds the blind window between
                // pings (worst-case undetected prefix of a hang).
                if (!sleepQuietly(idleGapMs)) return@Thread
            }
        }, "scout-anr-watchdog")
        watchdogThread?.start()
    }

    fun stop() {
        running = false
        watchdogThread?.interrupt()
        watchdogThread = null
    }

    private fun sleepQuietly(ms: Long): Boolean =
        try {
            Thread.sleep(ms)
            true
        } catch (e: InterruptedException) {
            false
        }
}
