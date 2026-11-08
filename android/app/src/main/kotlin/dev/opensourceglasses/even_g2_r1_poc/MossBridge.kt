package dev.opensourceglasses.even_g2_r1_poc

import android.content.*
import android.os.*
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Bounded single-flight bridge; no audio or transcript content enters logs. */
internal class MossBridge(private val context: Context, private val requestExitReport: () -> Unit) : ServiceConnection {
    private val handler = Handler(Looper.getMainLooper())
    private var service: Messenger? = null
    private var bound = false
    private var pending: MethodChannel.Result? = null
    private var request: Message? = null
    private var generation = 0L
    private val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (message.data.getLong("id") == generation) {
            val result = pending
            pending = null
            request = null
            handler.removeCallbacksAndMessages(null)
            if (message.data.getBoolean("failed")) {
                result?.error("moss_failed", "MOSS could not process the request. Audio remains saved.", null)
            } else {
                result?.success(mapOf(
                    "text" to message.data.getString("text"),
                    "decodeMs" to message.data.getLong("decodeMs"),
                    "provider" to message.data.getString("provider"),
                    "model" to message.data.getString("model"),
                    "profile" to message.data.getLongArray("profile")?.toList(),
                    "osApi" to message.data.getInt("osApi"),
                    "osRelease" to message.data.getString("osRelease"),
                    "appBuild" to message.data.getLong("appBuild"),
                    "language" to message.data.getString("language"),
                    "languagePolicy" to message.data.getString("languagePolicy"),
                    "nativeAdapter" to message.data.getString("nativeAdapter"),
                ))
            }
        }
        true
    })

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "close") { dispose(); result.success(null); return }
        if (call.method != "prepare" && call.method != "transcribe") { result.notImplemented(); return }
        if (pending != null) { result.error("moss_busy", "MOSS is already processing audio.", null); return }
        generation++
        pending = result
        request = Message.obtain(null, if (call.method == "prepare") 1 else 2).apply {
            data = Bundle().apply {
                putLong("id", generation)
                putString("modelPath", call.argument<String>("modelPath"))
                putString("provider", call.argument<String>("provider"))
                putString("modelId", call.argument<String>("modelId"))
                putString("language", call.argument<String>("language"))
                putString("wavPath", call.argument<String>("wavPath"))
            }
            replyTo = replies
        }
        handler.postDelayed({
            fail("moss_timeout")
            dispose()
            runCatching { requestExitReport() }
        }, if (service == null) 15_000 else 190_000)
        if (service != null) send() else if (!bound) {
            bound = context.bindService(Intent(context, MossService::class.java), this, Context.BIND_AUTO_CREATE or Context.BIND_IMPORTANT)
            if (!bound) fail("moss_unavailable")
        }
    }

    private fun send() {
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({ fail("moss_timeout"); dispose() }, 190_000)
        runCatching { service?.send(request) }.onFailure { onServiceDisconnected(null) }
    }

    override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
        service = Messenger(binder)
        runCatching { requestExitReport() }
        if (request != null) send()
    }
    override fun onServiceDisconnected(name: ComponentName?) {
        fail("moss_process_stopped")
        reset()
        runCatching { requestExitReport() }
    }
    override fun onBindingDied(name: ComponentName?) = onServiceDisconnected(name)
    override fun onNullBinding(name: ComponentName?) = onServiceDisconnected(name)
    private fun fail(code: String) {
        val result = pending
        pending = null
        request = null
        handler.removeCallbacksAndMessages(null)
        result?.error(code, "MOSS is unavailable. Audio remains saved.", null)
    }
    private fun reset() {
        service = null
        if (bound) runCatching { context.unbindService(this) }
        bound = false
    }
    fun dispose() {
        runCatching { service?.send(Message.obtain(null, 3)) }
        fail("moss_closed")
        reset()
    }
}
