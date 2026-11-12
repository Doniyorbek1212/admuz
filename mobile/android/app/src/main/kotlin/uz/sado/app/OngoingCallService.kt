package uz.sado.app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Foreground service for a running call: Android cuts the microphone (and camera) of an app in the
 * background unless such a service runs, so without it the call goes silent once the user leaves the app.
 * The ongoing notification (Telegram style) shows who is on the call and how long it has run; tapping it returns.
 */
class OngoingCallService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE).orEmpty()
        val text = intent?.getStringExtra(EXTRA_TEXT).orEmpty()
        val since = intent?.getLongExtra(EXTRA_SINCE, 0L) ?: 0L
        val video = intent?.getBooleanExtra(EXTRA_VIDEO, false) ?: false
        try {
            startForegroundCompat(buildNotification(title, text, since), video)
        } catch (error: RuntimeException) {
            // Android 14 refuses a microphone service started from the background; the call still runs while visible.
            Log.w(TAG, "call service not started: $error")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun buildNotification(title: String, text: String, since: Long): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, title.ifEmpty { "Calls" }, NotificationManager.IMPORTANCE_LOW)
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
        }
        val open = PendingIntent.getActivity(
            this,
            1,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP).putExtra(MainActivity.EXTRA_OPEN_CALL, true),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_CALL)
        if (since > 0) builder.setWhen(since).setUsesChronometer(true).setShowWhen(true) else builder.setShowWhen(false)
        return builder.build()
    }

    private fun startForegroundCompat(notification: Notification, video: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            // The camera type needs the permission already granted, or the start throws.
            if (video && checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            }
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        private const val CHANNEL_ID = "ongoing_call"
        private const val NOTIFICATION_ID = 0x5AD1
        private const val TAG = "OngoingCall"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_SINCE = "since"
        private const val EXTRA_VIDEO = "video"

        /** Starts or refreshes the notification; never throws. */
        fun start(context: Context, title: String, text: String, since: Long, video: Boolean) {
            val intent = Intent(context, OngoingCallService::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_TEXT, text)
                .putExtra(EXTRA_SINCE, since)
                .putExtra(EXTRA_VIDEO, video)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent) else context.startService(intent)
            } catch (error: RuntimeException) {
                Log.w(TAG, "call service not started: $error")
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, OngoingCallService::class.java))
        }
    }
}
