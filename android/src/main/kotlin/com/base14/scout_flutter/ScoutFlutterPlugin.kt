package com.base14.scout_flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

class ScoutFlutterPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var anrWatchdog: AnrWatchdog? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.base14.scout_flutter")
        channel.setMethodCallHandler(this)
        context = binding.applicationContext

        // Install crash handlers as early as possible.
        CrashReporter.install(binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        anrWatchdog?.stop()
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startAnrDetection" -> {
                val thresholdMs = call.argument<Int>("thresholdMs")?.toLong() ?: 5000L
                anrWatchdog?.stop()
                anrWatchdog = AnrWatchdog(thresholdMs) { durationMs ->
                    Handler(Looper.getMainLooper()).post {
                        channel.invokeMethod("onAnrDetected", durationMs)
                    }
                }
                anrWatchdog?.start()
                result.success(null)
            }
            "stopAnrDetection" -> {
                anrWatchdog?.stop()
                anrWatchdog = null
                result.success(null)
            }
            "simulateAnr" -> {
                val durationMs = call.argument<Int>("durationMs")?.toLong() ?: 6000L
                // Block the native main thread to trigger the ANR watchdog
                Thread.sleep(durationMs)
                result.success(null)
            }
            "getMemoryUsage" -> {
                val runtime = Runtime.getRuntime()
                val usedMemory = runtime.totalMemory() - runtime.freeMemory()
                val maxMemory = runtime.maxMemory()
                result.success(mapOf(
                    "used" to usedMemory,
                    "max" to maxMemory
                ))
            }
            "getCpuUsage" -> {
                try {
                    val pid = android.os.Process.myPid()
                    val procFile = java.io.File("/proc/$pid/stat")
                    val statLine = procFile.readText().trim().split(" ")
                    val utime = statLine[13].toLong()
                    val stime = statLine[14].toLong()
                    val totalTicks = utime + stime
                    result.success(mapOf(
                        "ticks" to totalTicks
                    ))
                } catch (e: Exception) {
                    result.success(mapOf("ticks" to -1L))
                }
            }
            "getNativeCrashReports" -> {
                val reports = CrashReporter.getPendingCrashReports()
                result.success(reports)
            }
            else -> result.notImplemented()
        }
    }
}
