package dev.opensourceglasses.even_g2_r1_poc

import android.app.Service
import android.content.Intent
import android.os.*
import android.util.Log
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

internal object MossNative {
    init { System.loadLibrary("workbench_moss") }
    external fun load(path: String, useGpu: Boolean): Boolean
    external fun transcribe(path: String): String?
    external fun profile(): LongArray
    external fun languagePolicy(): String
    external fun adapterRevision(): String
}

/** One model and one serial worker, isolated from durable capture. */
class MossService : Service() {
    private val worker = Executors.newSingleThreadExecutor()
    private val watchdog = Executors.newSingleThreadScheduledExecutor()
    private var loaded = false
    private var provider = "cpu"
    private var modelId = "moss-0.9b-q5_k"
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (message.what == 3) {
            Log.i("WorkBench", "[WorkBench][MOSS] state=released provider=$provider")
            android.os.Process.killProcess(android.os.Process.myPid())
        } else {
            val request = Message.obtain().apply { copyFrom(message) }
            worker.execute { perform(request) }
        }
        true
    })

    override fun onBind(intent: Intent) = messenger.binder

    private fun perform(message: Message) {
        val timeout = watchdog.schedule({
            Log.e("WorkBench", "[WorkBench][MOSS] state=timeout provider=$provider")
            android.os.Process.killProcess(android.os.Process.myPid())
        }, 180, TimeUnit.SECONDS)
        val began = SystemClock.elapsedRealtime()
        val response = Bundle().apply { putLong("id", message.data.getLong("id")) }
        try {
            check(message.data.getString("language") == "en")
            when (message.what) {
                1 -> {
                    val desiredModel = message.data.getString("modelId") ?: "moss-0.9b-q5_k"
                    val directory = when (desiredModel) {
                        "moss-0.9b-q5_k" -> "moss-0.9b"
                        "moss-0.9b-q4_0" -> "moss-0.9b-q4_0"
                        else -> error("unsupported_model")
                    }
                    val expected = File(filesDir, "workbench/models/$directory/model.gguf")
                    val requested = File(message.data.getString("modelPath") ?: "")
                    check(requested.canonicalFile == expected.canonicalFile && requested.isFile)
                    val desired = message.data.getString("provider") ?: "cpu"
                    check(desired == "cpu" || desired == "opencl")
                    modelId = desiredModel
                    provider = desired
                    loaded = MossNative.load(requested.path, desired == "opencl")
                    check(loaded)
                    check(MossNative.languagePolicy() == "english-latin-v2")
                    check(MossNative.adapterRevision() == "strict-provider-f16-1")
                    Log.i("WorkBench", "[WorkBench][MOSS] state=ready model=$modelId provider=$provider language=en threads=4 load_ms=${SystemClock.elapsedRealtime() - began}")
                }
                2 -> {
                    check(loaded)
                    val wav = File(message.data.getString("wavPath") ?: "")
                    val root = File(filesDir, "workbench/audio/moss").canonicalFile
                    check(wav.canonicalFile.parentFile == root && wav.extension == "wav")
                    check(wav.length() in 45..(90L * 32000 + 44))
                    Log.i("WorkBench", "[WorkBench][MOSS] state=processing model=$modelId provider=$provider language=en threads=4")
                    val text = checkNotNull(MossNative.transcribe(wav.path))
                    val profile = MossNative.profile()
                    if (provider == "opencl") check(profile[1] > 0 && profile[2] == 0L && profile[3] > 0 && profile[4] > 0)
                    response.putLongArray("profile", profile)
                    response.putString("provider", provider)
                    response.putString("model", modelId)
                    response.putString("language", "en")
                    response.putString("languagePolicy", MossNative.languagePolicy())
                    response.putString("nativeAdapter", MossNative.adapterRevision())
                    response.putInt("osApi", Build.VERSION.SDK_INT)
                    response.putString("osRelease", Build.VERSION.RELEASE)
                    response.putLong("appBuild", packageManager.getPackageInfo(packageName, 0).longVersionCode)
                    response.putString("text", text)
                    response.putLong("decodeMs", SystemClock.elapsedRealtime() - began)
                    Log.i("WorkBench", "[WorkBench][MOSS] state=completed model=$modelId provider=$provider language=en threads=4 decode_ms=${SystemClock.elapsedRealtime() - began} gpu_nodes=${profile[1]} cpu_nodes=${profile[2]} gpu_ns=${profile[3]} gpu_queries=${profile[4]}")
                }
                else -> error("invalid_request")
            }
        } catch (_: Throwable) {
            response.putBoolean("failed", true)
            Log.e("WorkBench", "[WorkBench][MOSS] state=failed provider=$provider")
        } finally {
            timeout.cancel(false)
        }
        runCatching { message.replyTo.send(Message.obtain(null, message.what).apply { data = response }) }
    }

    override fun onDestroy() {
        worker.shutdownNow()
        watchdog.shutdownNow()
        super.onDestroy()
        // Native inference cannot be interrupted by Java thread interruption.
        // An unbound/destroyed service must not leave an orphan model running.
        Log.i("WorkBench", "[WorkBench][MOSS] state=released reason=service_destroyed provider=$provider")
        android.os.Process.killProcess(android.os.Process.myPid())
    }
}
