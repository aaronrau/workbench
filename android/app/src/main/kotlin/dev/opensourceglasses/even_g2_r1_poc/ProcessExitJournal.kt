package dev.opensourceglasses.even_g2_r1_poc

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.system.OsConstants
import android.util.AtomicFile
import androidx.annotation.RequiresApi
import java.io.File
import java.io.FileNotFoundException
import org.json.JSONArray
import org.json.JSONObject

/** Reads Android's surviving exit records; SIGKILL cannot run an in-process handler. */
@RequiresApi(Build.VERSION_CODES.R)
internal class ProcessExitJournal(private val context: Context) {
    companion object {
        private const val MAX_EVENTS = 64
        private const val MAX_BYTES = 128 * 1024
        private val lock = Any()
    }

    fun capture(): List<KillExitEvent> = synchronized(lock) {
        val manager = context.getSystemService(ActivityManager::class.java)
        val recent = manager.getHistoricalProcessExitReasons(context.packageName, 0, 32)
            .mapNotNull { exit ->
                val process = when (exit.processName) {
                    context.packageName -> "app"
                    "${context.packageName}:gemma" -> "gemma"
                    else -> return@mapNotNull null
                }
                if (!KillExitEvent.isKillReason(exit.reason)) {
                    return@mapNotNull null
                }
                KillExitEvent(
                    exit.timestamp, process, exit.pid, exit.reason, exit.status,
                    exit.importance, exit.pss, exit.rss,
                )
            }
        val directory = File(context.filesDir, "workbench/runtime")
        check(directory.isDirectory || directory.mkdirs())
        val file = AtomicFile(File(directory, "kill-events.json"))
        val previous = read(file)
        val events = previous.associateBy { it.identity }.toMutableMap()
        val newEvents = recent.filter { it.identity !in events }
        for (event in recent) {
            events[event.identity] = event
        }
        val retained = events.values.sortedWith(
            compareBy<KillExitEvent> { it.timestampMs }.thenBy { it.pid },
        ).takeLast(MAX_EVENTS)
        if (retained != previous || !file.baseFile.exists()) {
            val data = JSONObject()
                .put("schema_version", 1)
                .put("low_memory_kill_reporting_supported", ActivityManager.isLowMemoryKillReportSupported())
                .put("events", JSONArray().apply { retained.forEach { put(it.toJson()) } })
                .toString().toByteArray(Charsets.UTF_8)
            check(data.size <= MAX_BYTES)
            val output = file.startWrite()
            try {
                output.write(data)
                file.finishWrite(output)
            } catch (error: Exception) {
                file.failWrite(output)
                throw error
            }
            check(file.openRead().use { it.readBytes().contentEquals(data) })
        }
        newEvents
    }

    private fun read(file: AtomicFile): List<KillExitEvent> {
        val data = try {
            file.openRead().use { input ->
                check(input.channel.size() <= MAX_BYTES)
                input.readBytes().toString(Charsets.UTF_8)
            }
        } catch (_: FileNotFoundException) {
            return emptyList()
        }
        val document = JSONObject(data)
        check(document.getInt("schema_version") == 1)
        val events = document.getJSONArray("events")
        check(events.length() <= MAX_EVENTS)
        // Reconstruct only numeric metadata and fixed labels, never arbitrary JSON fields.
        return (0 until events.length()).map { index ->
            val event = events.getJSONObject(index)
            KillExitEvent(
                event.getLong("timestamp_ms"), event.getString("process"),
                event.getInt("pid"), event.getInt("reason_code"), event.getInt("status"),
                event.getInt("importance"), event.getLong("last_sample_pss_kb"),
                event.getLong("last_sample_rss_kb"),
            )
        }
    }
}

internal data class KillExitEvent(
    val timestampMs: Long,
    val process: String,
    val pid: Int,
    val reasonCode: Int,
    val status: Int,
    val importance: Int,
    val lastSamplePssKb: Long,
    val lastSampleRssKb: Long,
) {
    companion object {
        fun isKillReason(reason: Int): Boolean =
            reason == ApplicationExitInfo.REASON_SIGNALED ||
                reason == ApplicationExitInfo.REASON_LOW_MEMORY
    }

    init {
        require(timestampMs > 0 && pid > 0)
        require(process == "app" || process == "gemma")
        require(isKillReason(reasonCode) && status in 0..255)
        require(importance >= 0 && lastSamplePssKb >= 0 && lastSampleRssKb >= 0)
    }

    val identity: Triple<Long, String, Int> get() = Triple(timestampMs, process, pid)
    val reason: String get() =
        if (reasonCode == ApplicationExitInfo.REASON_SIGNALED) "signaled" else "low_memory"
    val signalNumber: Int? get() =
        if (reasonCode == ApplicationExitInfo.REASON_SIGNALED) status else null
    val signalName: String? get() = signalNumber?.let { number ->
        when (number) {
            OsConstants.SIGKILL -> "SIGKILL"
            OsConstants.SIGABRT -> "SIGABRT"
            OsConstants.SIGSEGV -> "SIGSEGV"
            OsConstants.SIGTERM -> "SIGTERM"
            OsConstants.SIGBUS -> "SIGBUS"
            OsConstants.SIGILL -> "SIGILL"
            OsConstants.SIGFPE -> "SIGFPE"
            OsConstants.SIGQUIT -> "SIGQUIT"
            OsConstants.SIGHUP -> "SIGHUP"
            OsConstants.SIGINT -> "SIGINT"
            else -> "unknown"
        }
    }

    fun toJson(): JSONObject = JSONObject()
        .put("timestamp_ms", timestampMs)
        .put("process", process)
        .put("pid", pid)
        .put("reason", reason)
        .put("reason_code", reasonCode)
        .put("status", status)
        .put("signal_number", signalNumber ?: JSONObject.NULL)
        .put("signal", signalName ?: JSONObject.NULL)
        .put("importance", importance)
        .put("last_sample_pss_kb", lastSamplePssKb)
        .put("last_sample_rss_kb", lastSampleRssKb)
}
