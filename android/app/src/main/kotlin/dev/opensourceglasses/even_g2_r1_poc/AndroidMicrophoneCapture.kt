package dev.opensourceglasses.even_g2_r1_poc

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/** One producer and one outstanding Dart read; at most six seconds of PCM. */
internal class AndroidMicrophoneCapture(context: Context) {
    private val queue = ArrayBlockingQueue<ByteArray>(60)
    private val recorder: AudioRecord
    @Volatile private var recording = false
    @Volatile private var failure: String? = null
    private var worker: Thread? = null

    init {
        val manager = context.getSystemService(AudioManager::class.java)
        val microphone = manager.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }
            ?: throw IllegalStateException("Phone microphone unavailable")
        val minimum = AudioRecord.getMinBufferSize(
            16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        check(minimum > 0) { "Phone microphone format unavailable" }
        recorder = AudioRecord.Builder()
            .setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            .setAudioFormat(AudioFormat.Builder()
                .setSampleRate(16000)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setBufferSizeInBytes(maxOf(minimum, 32000))
            .build()
        try {
            check(recorder.state == AudioRecord.STATE_INITIALIZED &&
                recorder.sampleRate == 16000 && recorder.channelCount == 1 &&
                recorder.audioFormat == AudioFormat.ENCODING_PCM_16BIT) {
                "Phone microphone format unavailable"
            }
            check(recorder.setPreferredDevice(microphone)) {
                "Phone microphone route unavailable"
            }
        } catch (error: Exception) {
            recorder.release()
            throw error
        }
    }

    fun start() {
        recorder.startRecording()
        check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
            "Phone microphone did not start"
        }
        recording = true
        worker = Thread({
            try {
                while (recording) {
                    val samples = ShortArray(1600)
                    val count = recorder.read(samples, 0, samples.size, AudioRecord.READ_BLOCKING)
                    if (count < 0) {
                        if (recording) failure = "Microphone read failed"
                        break
                    }
                    if (count == 0) continue
                    // The preferred device is a request; verify the actual route.
                    if (recorder.routedDevice?.type != AudioDeviceInfo.TYPE_BUILTIN_MIC) {
                        failure = "Phone microphone route changed"
                        break
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                        recorder.activeRecordingConfiguration?.isClientSilenced == true) {
                        failure = "Phone microphone is muted or in use"
                        break
                    }
                    val bytes = ByteArray(count * 2)
                    for (index in 0 until count) {
                        val sample = samples[index].toInt()
                        bytes[index * 2] = sample.toByte()
                        bytes[index * 2 + 1] = (sample shr 8).toByte()
                    }
                    if (!queue.offer(bytes)) {
                        failure = "Microphone buffer full; recording stopped"
                        break
                    }
                }
            } catch (_: Exception) {
                if (recording) failure = "Microphone recording interrupted"
            } finally {
                recording = false
                try { recorder.stop() } catch (_: Exception) { }
            }
        }, "workbench-phone-microphone").apply { start() }
    }

    /** Return buffered audio before reporting failure so accepted samples survive. */
    fun read(): ByteArray? {
        val bytes = queue.poll(250, TimeUnit.MILLISECONDS)
        if (bytes != null) return bytes
        failure?.let { throw IllegalStateException(it) }
        return if (recording) ByteArray(0) else null
    }

    fun stop() {
        recording = false
        try { recorder.stop() } catch (_: Exception) { }
        worker?.join(2000)
        check(worker?.isAlive != true) { "Microphone stop timed out" }
    }

    fun release() {
        stop()
        recorder.release()
    }
}
