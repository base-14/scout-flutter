package com.base14.scout_flutter

import android.os.Handler
import android.os.Looper

class AnrWatchdog(
    private val thresholdMs: Long,
    private val onAnrDetected: (Long) -> Unit
) {
    private var watchdogThread: Thread? = null
    @Volatile private var running = false
    @Volatile private var responded = true

    private val mainHandler = Handler(Looper.getMainLooper())

    fun start() {
        running = true
        responded = true
        watchdogThread = Thread({
            while (running) {
                responded = false
                mainHandler.post { responded = true }

                try {
                    Thread.sleep(thresholdMs)
                } catch (e: InterruptedException) {
                    break
                }

                if (!responded && running) {
                    onAnrDetected(thresholdMs)
                }
            }
        }, "scout-anr-watchdog")
        watchdogThread?.start()
    }

    fun stop() {
        running = false
        watchdogThread?.interrupt()
        watchdogThread = null
    }
}
