package com.base14.scout_flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.base14.scout.android.Scout
import io.base14.scout.android.ScoutBridge
import io.base14.scout.core.ScoutConfig
import io.base14.scout.core.ScoutRole
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
                anrWatchdog = AnrWatchdog(thresholdMs, onAnrDetected = { durationMs ->
                    val dump = ThreadDumpCollector.capture()
                    Handler(Looper.getMainLooper()).post {
                        val payload = HashMap<String, Any>()
                        payload["duration"] = durationMs
                        payload.putAll(dump)
                        channel.invokeMethod("onAnrDetected", payload)
                    }
                })
                anrWatchdog?.start()
                result.success(null)
            }
            "stopAnrDetection" -> {
                anrWatchdog?.stop()
                anrWatchdog = null
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
            "getExitInfoReports" -> {
                val ctx = context
                if (ctx == null) {
                    result.success(emptyList<Map<String, Any>>())
                } else {
                    val maxBytes = call.argument<Int>("maxTombstoneBytes") ?: 131072
                    result.success(ExitInfoCollector.collect(ctx, maxBytes))
                }
            }
            "initNativeDelegate" -> {
                val ctx = context
                if (ctx == null) {
                    result.success(false)
                    return
                }
                val ok = runCatching {
                    Scout.initialize(
                        ctx,
                        ScoutConfig(
                            serviceName = call.argument<String>("serviceName") ?: "",
                            endpoint = call.argument<String>("endpoint") ?: "",
                            environment = call.argument<String>("environment"),
                            headers = call.argument<Map<String, String>>("headers") ?: emptyMap(),
                            sessionSampleRate = (call.argument<Number>("sessionSampleRate"))?.toDouble() ?: 1.0,
                            role = ScoutRole.AUTO,
                            enableScreenTracking = false,
                            enableTapTracking = false,
                            enableStartupTracking = false,
                        ),
                    )
                }.isSuccess
                result.success(ok)
            }
            "ingestSpans" -> {
                ScoutBridge.ingestSpans(call.argument<String>("json") ?: "")
                result.success(null)
            }
            "ingestLogs" -> {
                ScoutBridge.ingestLogs(call.argument<String>("json") ?: "")
                result.success(null)
            }
            "ingestMetrics" -> {
                ScoutBridge.ingestMetrics(call.argument<String>("json") ?: "")
                result.success(null)
            }
            "pushBreadcrumbs" -> {
                ScoutBridge.pushBreadcrumbs(call.argument<String>("json") ?: "")
                result.success(null)
            }
            "setBreadcrumbs" -> {
                ScoutBridge.setBreadcrumbs(call.argument<String>("json") ?: "")
                result.success(null)
            }
            "readOwner" -> {
                result.success(ScoutBridge.readOwner())
            }
            "setScreen" -> {
                io.base14.scout.android.Scout.setScreen(call.argument<String>("name") ?: "")
                result.success(null)
            }
            "getTimezone" -> {
                result.success(java.util.TimeZone.getDefault().id)
            }
            "getOsBuild" -> {
                result.success(android.os.Build.DISPLAY ?: "")
            }
            "getCpuArch" -> {
                result.success(android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: "")
            }
            "isDeviceCompromised" -> {
                result.success(isDeviceRooted())
            }
            "getBatteryDischargeRate" -> {
                result.success(batteryDischargeRate())
            }
            else -> result.notImplemented()
        }
    }

    private fun batteryDischargeRate(): Long? {
        return try {
            val ctx = context ?: return null
            val bm = ctx.getSystemService(Context.BATTERY_SERVICE)
                as? android.os.BatteryManager ?: return null
            val current = bm.getLongProperty(
                android.os.BatteryManager.BATTERY_PROPERTY_CURRENT_NOW,
            )
            if (current == Long.MIN_VALUE || current == 0L) null else current
        } catch (_: Throwable) {
            null
        }
    }

    private fun isDeviceRooted(): Boolean {
        return try {
            if (android.os.Build.TAGS?.contains("test-keys") == true) return true
            val rootPaths = arrayOf(
                "/system/bin/su", "/system/xbin/su", "/sbin/su",
                "/system/app/Superuser.apk", "/data/local/su",
                "/data/local/bin/su", "/data/local/xbin/su",
                "/system/sd/xbin/su", "/system/bin/failsafe/su",
                "/su/bin/su", "/sbin/.magisk", "/cache/.disable_magisk",
                "/dev/.magisk.unblock",
            )
            for (path in rootPaths) {
                if (java.io.File(path).exists()) return true
            }
            var p: Process? = null
            try {
                p = Runtime.getRuntime().exec(arrayOf("/system/xbin/which", "su"))
                val found = p.inputStream.bufferedReader().use { it.readLine() != null }
                if (found) return true
            } catch (_: Throwable) {
            } finally {
                try { p?.destroy() } catch (_: Throwable) {}
            }
            val pm = context?.packageManager
            if (pm != null) {
                val rootPackages = arrayOf(
                    "com.devadvance.rootcloak",
                    "com.devadvance.rootcloakplus",
                    "com.koushikdutta.superuser",
                    "com.thirdparty.superuser",
                    "eu.chainfire.supersu",
                    "com.noshufou.android.su",
                    "com.topjohnwu.magisk",
                )
                for (pkg in rootPackages) {
                    try {
                        pm.getPackageInfo(pkg, 0)
                        return true
                    } catch (_: android.content.pm.PackageManager.NameNotFoundException) {}
                }
            }
            false
        } catch (_: Throwable) {
            false
        }
    }
}
