package uz.sado.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Foreground service that keeps the app process (and with it the Flutter engine and TDLib) alive
 * when the UI is closed, so messages keep arriving as notifications without Firebase push.
 */
class KeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat(buildNotification())
        return START_STICKY
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, getString(R.string.keepalive_channel), NotificationManager.IMPORTANCE_MIN)
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_MIN)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(getString(R.string.keepalive_title))
            .setContentText(getString(R.string.keepalive_text))
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        const val CHANNEL = "uz.sado.app/keepalive"
        private const val CHANNEL_ID = "keepalive"
        private const val NOTIFICATION_ID = 0x5AD0
        private const val TAG = "KeepAlive"

        // Written by Dart's shared_preferences (key "keepAlive"), read here before Dart runs.
        private const val PREFS = "FlutterSharedPreferences"
        private const val KEY = "flutter.keepAlive"

        fun isEnabled(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY, true)

        fun setEnabled(context: Context, enabled: Boolean) {
            if (enabled) start(context) else context.stopService(Intent(context, KeepAliveService::class.java))
        }

        /** Never throws: Android 12+ refuses foreground starts from the background, which is retried on the next app open. */
        fun start(context: Context) {
            val intent = Intent(context, KeepAliveService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent) else context.startService(intent)
            } catch (error: RuntimeException) {
                Log.w(TAG, "keep-alive service not started: $error")
            }
        }
    }
}
