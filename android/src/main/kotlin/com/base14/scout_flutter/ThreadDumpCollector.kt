package com.base14.scout_flutter

import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject

object ThreadDumpCollector {

    private const val MAX_BYTES = 32_000
    private const val MAX_FRAMES_PER_THREAD = 64

    fun capture(): Map<String, Any> {
        val out = HashMap<String, Any>()
        try {
            val mainThread = Looper.getMainLooper().thread
            out["main_thread_stack"] = formatStack(mainThread.stackTrace)
        } catch (_: Throwable) {
        }
        try {
            val all = Thread.getAllStackTraces()
            out["thread_count"] = all.size
            out["threads_json"] = threadsJson(all)
        } catch (_: Throwable) {
        }
        return out
    }

    private fun formatStack(frames: Array<StackTraceElement>): String {
        val sb = StringBuilder()
        var count = 0
        for (frame in frames) {
            if (count >= MAX_FRAMES_PER_THREAD) {
                sb.append("...")
                break
            }
            sb.append(frame.toString()).append('\n')
            count++
        }
        return sb.toString()
    }

    private fun threadsJson(all: Map<Thread, Array<StackTraceElement>>): String {
        val arr = JSONArray()
        var totalBytes = 0
        for ((thread, frames) in all) {
            val obj = JSONObject()
            obj.put("name", thread.name)
            obj.put("state", thread.state.name)
            obj.put("priority", thread.priority)
            obj.put("daemon", thread.isDaemon)
            val frameArr = JSONArray()
            var count = 0
            for (frame in frames) {
                if (count >= MAX_FRAMES_PER_THREAD) break
                frameArr.put(frame.toString())
                count++
            }
            obj.put("frames", frameArr)
            val rendered = obj.toString()
            if (totalBytes + rendered.length > MAX_BYTES) break
            arr.put(obj)
            totalBytes += rendered.length
        }
        return arr.toString()
    }
}
