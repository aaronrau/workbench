package dev.opensourceglasses.even_g2_r1_poc

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/** Explicit microphone ownership, independent of the Bluetooth foreground service. */
class MicrophoneCaptureService : Service() {
    companion object {
        internal var instance: MicrophoneCaptureService? = null
        internal var pendingStart: ((String?) -> Unit)? = null
        private const val CHANNEL_ID = "workbench_microphone"
    }

    internal var capture: AndroidMicrophoneCapture? = null
        private set
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Never resume recording after process death or an unsolicited service start.
        val callback = pendingStart
        pendingStart = null
        if (callback == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        instance = this
        try {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(
                CHANNEL_ID, "Phone microphone", NotificationManager.IMPORTANCE_LOW,
            ))
            val openApp = PendingIntent.getActivity(this, 0,
                Intent(this, MainActivity::class.java).apply {
                    this.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                }, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val notification = NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(applicationInfo.icon)
                .setContentTitle("Work Bench microphone active")
                .setContentText("Recording phone audio for local transcription")
                .setContentIntent(openApp)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(2408, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(2408, notification)
            }
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:phoneMicrophone")
                .apply { setReferenceCounted(false); acquire() }
            capture = AndroidMicrophoneCapture(applicationContext)
            capture!!.start()
            callback(null)
        } catch (_: Exception) {
            callback("Phone microphone could not start")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    @Synchronized
    internal fun releaseCapture() {
        val previous = capture
        capture = null
        previous?.release()
    }

    override fun onDestroy() {
        try { releaseCapture() } catch (_: Exception) { }
        if (instance === this) instance = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
