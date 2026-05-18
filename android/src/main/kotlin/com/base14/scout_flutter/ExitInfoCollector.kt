package com.base14.scout_flutter

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import androidx.annotation.RequiresApi
import java.io.BufferedReader
import java.io.InputStreamReader

/**
 * Drains `ApplicationExitInfo` records — Android's authoritative
 * post-mortem feed for every reason a process died: ANR, OOM kill,
 * native crash, JVM uncaught exception, low-memory kill, user force-stop.
 *
 * Available from API 30 (Android 11). On older versions we return an
 * empty list and the SDK falls back to the in-process JVM handler +
 * NDK signal handler we ship.
 *
 * `getSubReason()` only exists on API 31+; pulled reflectively so the
 * compile target can stay on 30 without a guard cliff.
 *
 * Records are returned newest-first and de-duplicated by timestamp on
 * the Dart side; we don't track "seen" state here because the OS
 * already caps the buffer at 16 entries.
 */
object ExitInfoCollector {

    /** Drain all historical exit reasons. Empty list on API < 30. */
    fun collect(context: Context): List<Map<String, Any>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return emptyList()
        }
        return collectInternal(context)
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun collectInternal(context: Context): List<Map<String, Any>> {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return emptyList()

        val infos: List<ApplicationExitInfo> = try {
            am.getHistoricalProcessExitReasons(
                context.packageName,
                /* pid = */ 0,
                /* maxNum = */ 16,
            )
        } catch (_: Throwable) {
            return emptyList()
        }

        val out = mutableListOf<Map<String, Any>>()
        for (info in infos) {
            try {
                out.add(parse(info))
            } catch (_: Throwable) {
                // Skip a single malformed record rather than losing them all.
            }
        }
        return out
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun parse(info: ApplicationExitInfo): Map<String, Any> {
        val map = mutableMapOf<String, Any>()
        map["crash_type"] = reasonName(info.reason)
        map["crash_reason"] = info.description ?: reasonName(info.reason)
        map["crash_timestamp"] = isoTimestamp(info.timestamp)
        map["crash_death_timestamp_ms"] = info.timestamp
        map["crash_importance"] = info.importance
        map["crash_exit_status"] = info.status
        map["crash_pid"] = info.pid
        map["crash_pss_kb"] = info.pss
        map["crash_rss_kb"] = info.rss
        map["crash_process_name"] = info.processName

        // API 31+ adds a subReason int (e.g. SUBREASON_TOO_MANY_EMPTY).
        // Read it reflectively so we don't pin the build to a higher
        // compileSdkVersion.
        try {
            val sub = info.javaClass.getMethod("getSubReason").invoke(info) as? Int
            if (sub != null) map["crash_subreason"] = sub
        } catch (_: Throwable) {
            // Method missing on this OS version — ignore.
        }

        // The trace input stream is the tombstone-like blob the
        // platform attaches to ANRs and native crashes. It can be
        // multi-megabyte for ANR full thread dumps, so we cap it.
        if (info.reason == ApplicationExitInfo.REASON_ANR ||
            info.reason == ApplicationExitInfo.REASON_CRASH_NATIVE ||
            info.reason == ApplicationExitInfo.REASON_CRASH
        ) {
            map["crash_tombstone"] = readTombstone(info)
        }

        return map
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun readTombstone(info: ApplicationExitInfo): String {
        return try {
            info.traceInputStream?.use { stream ->
                BufferedReader(InputStreamReader(stream)).use { reader ->
                    val sb = StringBuilder()
                    var line: String?
                    var total = 0
                    val cap = 32_000 // OTLP payload-friendly cap
                    while (reader.readLine().also { line = it } != null) {
                        val ln = line!!
                        if (total + ln.length > cap) {
                            sb.append("\n[truncated]")
                            break
                        }
                        sb.append(ln).append('\n')
                        total += ln.length + 1
                    }
                    sb.toString()
                }
            } ?: ""
        } catch (_: Throwable) {
            ""
        }
    }

    private fun reasonName(reason: Int): String {
        // Stable string names so the Dart side doesn't need the numeric
        // ApplicationExitInfo constants. Names match the SDK constants.
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            when (reason) {
                ApplicationExitInfo.REASON_UNKNOWN -> "unknown"
                ApplicationExitInfo.REASON_EXIT_SELF -> "exit_self"
                ApplicationExitInfo.REASON_SIGNALED -> "signaled"
                ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
                ApplicationExitInfo.REASON_CRASH -> "jvm_crash"
                ApplicationExitInfo.REASON_CRASH_NATIVE -> "native_crash"
                ApplicationExitInfo.REASON_ANR -> "anr"
                ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "init_failure"
                ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "permission_change"
                ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "excessive_resources"
                ApplicationExitInfo.REASON_USER_REQUESTED -> "user_requested"
                ApplicationExitInfo.REASON_USER_STOPPED -> "user_stopped"
                ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "dependency_died"
                ApplicationExitInfo.REASON_OTHER -> "other"
                else -> "unknown"
            }
        } else {
            "unknown"
        }
    }

    private fun isoTimestamp(ms: Long): String {
        val format = java.text.SimpleDateFormat(
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
            java.util.Locale.US,
        )
        format.timeZone = java.util.TimeZone.getTimeZone("UTC")
        return format.format(java.util.Date(ms))
    }
}
