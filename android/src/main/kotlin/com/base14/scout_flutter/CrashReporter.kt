package com.base14.scout_flutter

import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Debug
import android.os.StatFs
import android.os.SystemClock
import android.provider.Settings
import org.json.JSONObject
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

object CrashReporter {
    private const val CRASH_DIR_NAME = "scout_crashes"
    private const val CRASH_FILE_PREFIX = "crash_"
    private const val PREFS_NAME = "scout_crash_state"
    private const val PREF_SESSIONS_SINCE_LAST_CRASH = "sessions_since_last_crash"
    private const val PREF_LAUNCHES_SINCE_LAST_CRASH = "launches_since_last_crash"
    private const val PREF_ACTIVE_SINCE_LAST_CRASH = "active_secs_since_last_crash"
    private const val PREF_BG_SINCE_LAST_CRASH = "bg_secs_since_last_crash"
    private const val PREF_APP_UUID = "app_uuid"

    private var crashDir: File? = null
    private var previousHandler: Thread.UncaughtExceptionHandler? = null
    private var installed = false
    private var nativeAvailable = false

    private var sessionsSinceLaunch = 0
    private var launchesSinceLastCrash = 0

    private val activeTimeMs = AtomicInteger(0)
    private val backgroundTimeMs = AtomicInteger(0)
    private val activeSinceLastCrashMs = AtomicInteger(0)
    private val backgroundSinceLastCrashMs = AtomicInteger(0)
    @Volatile private var lastTransitionElapsedMs: Long = 0
    @Volatile private var currentlyForeground: Boolean = false
    private var appContext: Context? = null

    fun install(context: Context) {
        if (installed) return
        installed = true
        appContext = context.applicationContext

        crashDir = File(context.cacheDir, CRASH_DIR_NAME).also { it.mkdirs() }

        previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            writeCrashReport(thread, throwable)
            previousHandler?.uncaughtException(thread, throwable)
        }

        installNativeHandler(crashDir!!.absolutePath)
        if (nativeAvailable) {
            pushStartupContext(context)
            pushExtendedContext(context)
            pushMemoryAndStorage(context)
            registerForegroundTracking(context)
            primeSessionCounters(context)
            primeLaunchCounter(context)
            pushActivityTimers()
        }
    }

    private fun pushStartupContext(context: Context) {
        val model = "${Build.MANUFACTURER} ${Build.MODEL}".trim()
        val osVersion = Build.VERSION.RELEASE ?: ""
        val pkg = try {
            context.packageManager.getPackageInfo(context.packageName, 0)
        } catch (_: Exception) { null }
        val bundleVersion = pkg?.versionName ?: ""
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        var appUuid = prefs.getString(PREF_APP_UUID, null)
        if (appUuid.isNullOrEmpty()) {
            appUuid = UUID.randomUUID().toString()
            prefs.edit().putString(PREF_APP_UUID, appUuid).apply()
        }
        val (parentName, parentPid) = readParentProcInfo()
        try {
            nativeSetContext(model, osVersion, appUuid, bundleVersion, parentName, parentPid)
        } catch (_: UnsatisfiedLinkError) {}
    }

    private fun pushExtendedContext(context: Context) {
        val pm = context.packageManager
        val pkgName = context.packageName
        val pkgInfo = try { pm.getPackageInfo(pkgName, android.content.pm.PackageManager.GET_SIGNATURES) }
            catch (_: Exception) { null }
        val appInfo = try { pm.getApplicationInfo(pkgName, 0) } catch (_: Exception) { null }
        val processName = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) Application.getProcessName()
            else readProcSelfCmdline()
        } catch (_: Throwable) { "" } ?: ""
        val appName = appInfo?.let { pm.getApplicationLabel(it).toString() } ?: ""
        val executablePath = appInfo?.sourceDir ?: ""
        val appExecutable = if (executablePath.isNotEmpty()) File(executablePath).name else ""
        val appVersion = pkgInfo?.versionName ?: ""
        val deviceAppHash = computeDeviceAppHash(pkgName, pkgInfo)
        val idfv = try {
            Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID) ?: ""
        } catch (_: Throwable) { "" }
        val isDebug = (appInfo?.flags ?: 0) and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0
        val buildType = if (isDebug) "debug" else "release"
        val environment = System.getProperty("scout.environment") ?: ""
        val buildConfig = if (isDebug) "Debug" else "Release"
        val osBuild = Build.ID ?: ""
        val timeZone = TimeZone.getDefault().id
        val translated = detectTranslated()
        val gid = try {
            File("/proc/self/status").readText()
                .lineSequence().firstOrNull { it.startsWith("Gid:") }
                ?.substringAfter("Gid:")?.trim()?.split(Regex("\\s+"))?.firstOrNull()
                ?.toIntOrNull() ?: -1
        } catch (_: Throwable) { -1 }
        val nowEpochSecs = System.currentTimeMillis() / 1000
        val bootElapsedMs = SystemClock.elapsedRealtime()
        val systemBootTimeSecs = nowEpochSecs - bootElapsedMs / 1000
        val appStartTimeSecs = nowEpochSecs
        try {
            nativeSetExtendedContext(
                processName, appName, appExecutable, executablePath,
                appVersion, pkgName, deviceAppHash, idfv,
                buildType, environment, buildConfig, osBuild,
                timeZone, translated, gid,
                appStartTimeSecs, systemBootTimeSecs,
            )
        } catch (_: UnsatisfiedLinkError) {}
    }

    private fun pushMemoryAndStorage(context: Context) {
        val rt = Runtime.getRuntime()
        val rssBytes = try { Debug.getNativeHeapAllocatedSize() + (rt.totalMemory() - rt.freeMemory()) }
            catch (_: Throwable) { -1L }
        val data = try { StatFs(context.filesDir.absolutePath) } catch (_: Throwable) { null }
        val storageSize = data?.let { it.blockCountLong * it.blockSizeLong } ?: -1L
        val storageFree = data?.let { it.availableBlocksLong * it.blockSizeLong } ?: -1L
        try { nativeSetMemoryInfo(rssBytes, storageSize, storageFree) }
        catch (_: UnsatisfiedLinkError) {}
    }

    private fun pushActivityTimers() {
        try {
            nativeSetActivityTimers(
                activeTimeMs.get() / 1000,
                backgroundTimeMs.get() / 1000,
                activeSinceLastCrashMs.get() / 1000,
                backgroundSinceLastCrashMs.get() / 1000,
                launchesSinceLastCrash,
            )
        } catch (_: UnsatisfiedLinkError) {}
    }

    private fun primeLaunchCounter(context: Context) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        launchesSinceLastCrash = prefs.getInt(PREF_LAUNCHES_SINCE_LAST_CRASH, 0) + 1
        activeSinceLastCrashMs.set(prefs.getInt(PREF_ACTIVE_SINCE_LAST_CRASH, 0))
        backgroundSinceLastCrashMs.set(prefs.getInt(PREF_BG_SINCE_LAST_CRASH, 0))
        prefs.edit().putInt(PREF_LAUNCHES_SINCE_LAST_CRASH, launchesSinceLastCrash).apply()
    }

    private fun primeSessionCounters(context: Context) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val sinceLastCrash = prefs.getInt(PREF_SESSIONS_SINCE_LAST_CRASH, 0) + 1
        prefs.edit().putInt(PREF_SESSIONS_SINCE_LAST_CRASH, sinceLastCrash).apply()
        sessionsSinceLaunch = 1
        try { nativeSetSessionCounters(sessionsSinceLaunch, sinceLastCrash) }
        catch (_: UnsatisfiedLinkError) {}
    }

    fun notifySessionRotated(context: Context) {
        if (!nativeAvailable) return
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val sinceLastCrash = prefs.getInt(PREF_SESSIONS_SINCE_LAST_CRASH, 0) + 1
        prefs.edit().putInt(PREF_SESSIONS_SINCE_LAST_CRASH, sinceLastCrash).apply()
        sessionsSinceLaunch += 1
        try { nativeSetSessionCounters(sessionsSinceLaunch, sinceLastCrash) }
        catch (_: UnsatisfiedLinkError) {}
    }

    private fun registerForegroundTracking(context: Context) {
        val app = context.applicationContext as? Application ?: return
        lastTransitionElapsedMs = SystemClock.elapsedRealtime()
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            private var started = 0
            override fun onActivityStarted(activity: Activity) {
                started += 1
                if (started == 1) transitionTo(foreground = true)
            }
            override fun onActivityStopped(activity: Activity) {
                if (started > 0) started -= 1
                if (started == 0) transitionTo(foreground = false)
            }
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }

    @Synchronized
    private fun transitionTo(foreground: Boolean) {
        val now = SystemClock.elapsedRealtime()
        val elapsed = (now - lastTransitionElapsedMs).toInt().coerceAtLeast(0)
        if (currentlyForeground) {
            activeTimeMs.addAndGet(elapsed)
            activeSinceLastCrashMs.addAndGet(elapsed)
        } else {
            backgroundTimeMs.addAndGet(elapsed)
            backgroundSinceLastCrashMs.addAndGet(elapsed)
        }
        appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)?.edit()
            ?.putInt(PREF_ACTIVE_SINCE_LAST_CRASH, activeSinceLastCrashMs.get())
            ?.putInt(PREF_BG_SINCE_LAST_CRASH, backgroundSinceLastCrashMs.get())
            ?.apply()
        currentlyForeground = foreground
        lastTransitionElapsedMs = now
        try { nativeSetForegroundState(foreground, foreground) } catch (_: UnsatisfiedLinkError) {}
        pushActivityTimers()
    }

    private fun computeDeviceAppHash(pkgName: String, info: android.content.pm.PackageInfo?): String {
        val sig = try {
            @Suppress("DEPRECATION")
            info?.signatures?.firstOrNull()?.toByteArray()
        } catch (_: Throwable) { null } ?: return ""
        return try {
            val md = MessageDigest.getInstance("SHA-256")
            md.update(pkgName.toByteArray())
            md.update(sig)
            md.digest().joinToString("") { "%02x".format(it) }.take(32)
        } catch (_: Throwable) { "" }
    }

    private fun detectTranslated(): Boolean {
        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: return false
        if (abi.contains("x86")) return false
        return try {
            File("/proc/self/exe").canonicalPath.contains("houdini") ||
                File("/system/lib/arm").exists() ||
                File("/system/lib64/arm64").exists()
        } catch (_: Throwable) { false }
    }

    private fun readProcSelfCmdline(): String = try {
        File("/proc/self/cmdline").readBytes()
            .takeWhile { it != 0.toByte() }
            .toByteArray()
            .toString(Charsets.UTF_8)
    } catch (_: Throwable) { "" }

    private fun readParentProcInfo(): Pair<String, Int> {
        var ppid = -1
        var name = ""
        try {
            val status = File("/proc/self/status").readText()
            val pidLine = status.lineSequence().firstOrNull { it.startsWith("PPid:") }
            ppid = pidLine?.substringAfter("PPid:")?.trim()?.toIntOrNull() ?: -1
        } catch (_: Exception) {}
        if (ppid > 0) {
            name = try { File("/proc/$ppid/comm").readText().trim() } catch (_: Exception) { "" }
            if (name.isEmpty()) {
                name = try {
                    File("/proc/$ppid/cmdline").readBytes()
                        .takeWhile { it != 0.toByte() }
                        .toByteArray()
                        .toString(Charsets.UTF_8)
                } catch (_: Exception) { "" }
            }
        }
        return name to ppid
    }

    private fun android.content.pm.PackageInfo.longVersionCodeCompat(): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) longVersionCode
        else @Suppress("DEPRECATION") versionCode.toLong()

    fun clearSessionsSinceLastCrash(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
            .putInt(PREF_SESSIONS_SINCE_LAST_CRASH, 0)
            .putInt(PREF_LAUNCHES_SINCE_LAST_CRASH, 0)
            .putInt(PREF_ACTIVE_SINCE_LAST_CRASH, 0)
            .putInt(PREF_BG_SINCE_LAST_CRASH, 0)
            .apply()
        activeSinceLastCrashMs.set(0)
        backgroundSinceLastCrashMs.set(0)
        launchesSinceLastCrash = 0
        pushActivityTimers()
    }

    fun getPendingCrashReports(): List<Map<String, Any>> {
        val dir = crashDir ?: return emptyList()
        if (!dir.exists()) return emptyList()

        val stringKeys = arrayOf(
            "crash_type", "crash_reason", "crash_timestamp", "crash_thread_name",
            "crash_stack_trace", "crash_registers_json", "crash_memory_map",
            "crash_cpu_arch", "crash_build_fingerprint", "crash_kernel_version",
            "crash_machine", "crash_device_model", "crash_os_name", "crash_os_version",
            "crash_os_build", "crash_app_uuid", "crash_bundle_id", "crash_bundle_version",
            "crash_app_version", "crash_app_name", "crash_process_name", "crash_app_executable",
            "crash_executable_path", "crash_device_app_hash", "crash_idfv",
            "crash_build_type", "crash_environment", "crash_build_configuration",
            "crash_time_zone", "crash_system_boot_time_iso", "crash_app_start_time",
            "crash_parent_proc_name", "crash_signal", "crash_fault_address",
            "crash_exception_register", "crash_report_id", "crash_report_type",
            "crash_report_version",
        )
        val intKeys = arrayOf(
            "crash_pid", "crash_tid", "crash_uid", "crash_gid", "crash_parent_pid",
            "crash_process_uptime_secs", "crash_signal_code", "crash_signal_number",
            "crash_thread_index", "crash_thread_count", "crash_binary_images_count",
            "crash_app_sessions_since_launch", "crash_app_sessions_since_last_crash",
            "crash_app_launches_since_last_crash",
            "crash_app_active_time_secs", "crash_app_background_time_secs",
            "crash_app_active_time_since_last_crash_secs",
            "crash_app_background_time_since_last_crash_secs",
        )
        val longKeys = arrayOf(
            "crash_time_since_boot_secs", "crash_memory_free_bytes",
            "crash_memory_size_bytes", "crash_storage_size_bytes", "crash_storage_free_bytes",
        )
        val boolKeys = arrayOf(
            "crash_app_in_foreground", "crash_app_active", "crash_translated",
        )
        val rawJsonKeys = arrayOf("crash_binary_images_json")

        val reports = mutableListOf<Map<String, Any>>()
        val files = dir.listFiles { file -> file.name.startsWith(CRASH_FILE_PREFIX) } ?: return emptyList()

        for (file in files.sortedBy { it.lastModified() }) {
            try {
                val json = JSONObject(file.readText())
                val report = mutableMapOf<String, Any>()
                for (k in stringKeys) if (json.has(k)) report[k] = json.optString(k, "")
                for (k in intKeys) if (json.has(k)) report[k] = json.optInt(k, -1)
                for (k in longKeys) if (json.has(k)) report[k] = json.optLong(k, -1)
                for (k in boolKeys) if (json.has(k)) report[k] = json.optBoolean(k, false)
                for (k in rawJsonKeys) if (json.has(k)) {
                    val arr = json.optJSONArray(k)
                    if (arr != null) report[k] = arr.toString()
                }
                if (json.has("crash_signal_code_name")) {
                    report["crash_signal_code_name"] = json.optString("crash_signal_code_name", "")
                }
                reports.add(report)
            } catch (_: Exception) {}
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
                put("crash_report_id", UUID.randomUUID().toString().replace("-", ""))
                put("crash_report_type", "jvm_exception")
                put("crash_report_version", "1.0")
            }
            file.writeText(json.toString())
        } catch (_: Exception) {}
    }

    private fun installNativeHandler(crashDirPath: String) {
        try {
            System.loadLibrary("scout_crash_handler")
            nativeInstallSignalHandler(crashDirPath)
            nativeAvailable = true
        } catch (_: UnsatisfiedLinkError) {
            nativeAvailable = false
        }
    }

    private external fun nativeInstallSignalHandler(crashDirPath: String)
    private external fun nativeSetContext(
        model: String,
        osVersion: String,
        appUuid: String,
        bundleVersion: String,
        parentName: String,
        parentPid: Int,
    )
    private external fun nativeSetExtendedContext(
        processName: String, appName: String, appExecutable: String,
        executablePath: String, appVersion: String, bundleId: String,
        deviceAppHash: String, idfv: String, buildType: String,
        environment: String, buildConfiguration: String, osBuild: String,
        timeZone: String, translated: Boolean, gid: Int,
        appStartTimeSecs: Long, systemBootTimeSecs: Long,
    )
    private external fun nativeSetMemoryInfo(
        memorySizeBytes: Long, storageSizeBytes: Long, storageFreeBytes: Long,
    )
    private external fun nativeSetActivityTimers(
        activeTimeSecs: Int, backgroundTimeSecs: Int,
        activeSinceLastCrashSecs: Int, backgroundSinceLastCrashSecs: Int,
        launchesSinceLastCrash: Int,
    )
    private external fun nativeSetForegroundState(inForeground: Boolean, active: Boolean)
    private external fun nativeSetSessionCounters(sinceLaunch: Int, sinceLastCrash: Int)

    external fun nativeSimulateCrash()
}
