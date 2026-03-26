package com.base14.scout_flutter

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Native crash reporter for Android.
 *
 * Installs a Thread.setDefaultUncaughtExceptionHandler to capture JVM crashes.
 * Writes crash data to a file before the process dies. On next launch,
 * [getPendingCrashReports] retrieves and deletes the saved reports.
 *
 * Also loads the native signal handler for NDK-level crashes (SIGSEGV, etc.)
 * via JNI if the native library is available.
 */
object CrashReporter {
    private const val CRASH_DIR_NAME = "scout_crashes"
    private const val CRASH_FILE_PREFIX = "crash_"
    private var crashDir: File? = null
    private var previousHandler: Thread.UncaughtExceptionHandler? = null
    private var installed = false

    /**
     * Install crash handlers. Call once during plugin initialization.
     */
    fun install(context: Context) {
        if (installed) return
        installed = true

        crashDir = File(context.cacheDir, CRASH_DIR_NAME).also {
            it.mkdirs()
        }

        // Install JVM uncaught exception handler
        previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            writeCrashReport(thread, throwable)
            // Chain to previous handler (e.g. Android's default which shows crash dialog)
            previousHandler?.uncaughtException(thread, throwable)
        }

        // Install native signal handler for NDK crashes
        installNativeHandler(crashDir!!.absolutePath)
    }

    /**
     * Returns pending crash reports from the previous session and deletes them.
     *
     * Each report is a map with keys:
     * - crash_type: "jvm_exception" or "native_signal"
     * - crash_reason: exception message or signal name
     * - crash_timestamp: ISO 8601 timestamp
     * - crash_thread_name: thread that crashed
     * - crash_stack_trace: stack trace string
     */
    fun getPendingCrashReports(): List<Map<String, Any>> {
        val dir = crashDir ?: return emptyList()
        if (!dir.exists()) return emptyList()

        val reports = mutableListOf<Map<String, Any>>()
        val files = dir.listFiles { file -> file.name.startsWith(CRASH_FILE_PREFIX) } ?: return emptyList()

        for (file in files.sortedBy { it.lastModified() }) {
            try {
                val json = JSONObject(file.readText())
                val report = mutableMapOf<String, Any>()
                report["crash_type"] = json.optString("crash_type", "unknown")
                report["crash_reason"] = json.optString("crash_reason", "Unknown")
                report["crash_timestamp"] = json.optString("crash_timestamp", "")
                report["crash_thread_name"] = json.optString("crash_thread_name", "")
                report["crash_stack_trace"] = json.optString("crash_stack_trace", "")
                if (json.has("crash_registers")) {
                    report["crash_registers"] = json.optString("crash_registers", "")
                }
                if (json.has("crash_memory_map")) {
                    report["crash_memory_map"] = json.optString("crash_memory_map", "")
                }
                if (json.has("crash_signal_code")) {
                    report["crash_signal_code"] = json.optString("crash_signal_code", "")
                }
                if (json.has("crash_pid")) {
                    report["crash_pid"] = json.optInt("crash_pid", -1)
                }
                if (json.has("crash_tid")) {
                    report["crash_tid"] = json.optInt("crash_tid", -1)
                }
                if (json.has("crash_uid")) {
                    report["crash_uid"] = json.optInt("crash_uid", -1)
                }
                if (json.has("crash_abi")) {
                    report["crash_abi"] = json.optString("crash_abi", "")
                }
                if (json.has("crash_build_fingerprint")) {
                    report["crash_build_fingerprint"] = json.optString("crash_build_fingerprint", "")
                }
                if (json.has("crash_kernel")) {
                    report["crash_kernel"] = json.optString("crash_kernel", "")
                }
                if (json.has("crash_process_uptime_secs")) {
                    report["crash_process_uptime_secs"] = json.optInt("crash_process_uptime_secs", -1)
                }
                reports.add(report)
            } catch (_: Exception) {
                // Corrupted file — skip
            }
            file.delete()
        }

        return reports
    }

    private fun writeCrashReport(thread: Thread, throwable: Throwable) {
        try {
            val dir = crashDir ?: return
            val timestamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).format(Date())
            val file = File(dir, "${CRASH_FILE_PREFIX}${System.currentTimeMillis()}.json")

            val sw = StringWriter()
            throwable.printStackTrace(PrintWriter(sw))

            val json = JSONObject().apply {
                put("crash_type", "jvm_exception")
                put("crash_reason", "${throwable.javaClass.name}: ${throwable.message ?: ""}")
                put("crash_timestamp", timestamp)
                put("crash_thread_name", thread.name)
                put("crash_stack_trace", sw.toString())
            }

            // Use synchronous write — process is about to die.
            file.writeText(json.toString())
        } catch (_: Exception) {
            // Best effort — can't do anything if this fails.
        }
    }

    /**
     * Install native signal handler via JNI. If the native library is not available,
     * this silently fails — JVM crash reporting still works.
     */
    private fun installNativeHandler(crashDirPath: String) {
        try {
            System.loadLibrary("scout_crash_handler")
            nativeInstallSignalHandler(crashDirPath)
        } catch (_: UnsatisfiedLinkError) {
            // Native library not available — NDK crash reporting disabled.
            // JVM uncaught exception handler still works.
        }
    }

    private external fun nativeInstallSignalHandler(crashDirPath: String)
}
