package uz.sado.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * Media notification and lock-screen / headset controls for audio played by Dart's just_audio player
 * (Playback in lib/state/playback.dart). As a mediaPlayback foreground service it also keeps the
 * process alive with the UI closed. Button presses go back to Dart over [channel].
 * Not the audio_service plugin: it destroys the shared engine when its service stops, which would kill TDLib.
 */
class MusicService : Service() {
    private lateinit var session: MediaSession

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        session = MediaSession(this, TAG).apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() = send("play")
                override fun onPause() = send("pause")
                override fun onSkipToNext() = send("next")
                override fun onSkipToPrevious() = send("previous")
                override fun onStop() = send("stop")
                override fun onSeekTo(pos: Long) = send("seek", pos)
            })
            isActive = true
        }
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Notification buttons arrive as intent actions.
        val action = intent?.action
        if (action != null) send(action)
        if (action != ACTION_STOP) render()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        instance = null
        session.release()
        super.onDestroy()
    }

    fun render() {
        val state = current ?: return stopSelf()
        session.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, state.title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, state.artist)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, state.duration)
                .apply { state.art?.let { putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it) } }
                .build(),
        )
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(ACTIONS)
                .setState(
                    if (state.playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    state.position,
                    if (state.playing) state.speed else 0f,
                )
                .build(),
        )
        val notification = buildNotification(state)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(state: State): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, getString(R.string.music_channel), NotificationManager.IMPORTANCE_LOW)
            channel.setShowBadge(false)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val actions = buildList {
            add(action(android.R.drawable.ic_media_previous, R.string.music_previous, "previous"))
            if (state.playing) {
                add(action(android.R.drawable.ic_media_pause, R.string.music_pause, "pause"))
            } else {
                add(action(android.R.drawable.ic_media_play, R.string.music_play, "play"))
            }
            add(action(android.R.drawable.ic_media_next, R.string.music_next, "next"))
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        actions.forEach(builder::addAction)
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(state.title)
            .setContentText(state.artist)
            .setLargeIcon(state.art)
            .setContentIntent(open)
            // Swiping a paused notification away stops playback, like Telegram.
            .setDeleteIntent(serviceIntent(ACTION_STOP))
            .setOngoing(state.playing)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(session.sessionToken)
                    .setShowActionsInCompactView(*actions.indices.toList().toIntArray()),
            )
            .build()
    }

    private fun action(icon: Int, title: Int, action: String) =
        Notification.Action.Builder(Icon.createWithResource(this, icon), getString(title), serviceIntent(action)).build()

    private fun serviceIntent(action: String): PendingIntent = PendingIntent.getService(
        this,
        action.hashCode(),
        Intent(this, MusicService::class.java).setAction(action),
        PendingIntent.FLAG_IMMUTABLE,
    )

    private fun send(method: String, argument: Any? = null) {
        channel?.invokeMethod(method, argument)
    }

    private class State(
        val title: String,
        val artist: String,
        val artPath: String?,
        val art: Bitmap?,
        val playing: Boolean,
        val position: Long,
        val duration: Long,
        val speed: Float,
    )

    companion object {
        const val CHANNEL = "uz.sado.app/music"
        private const val CHANNEL_ID = "music"
        private const val NOTIFICATION_ID = 0x5AD1
        private const val TAG = "UZARO"
        private const val ACTION_STOP = "stop"
        private const val ACTIONS = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SEEK_TO or PlaybackState.ACTION_STOP or
            PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS

        /** Dart side of the controls; set by [MainApplication]. */
        var channel: MethodChannel? = null
        private var instance: MusicService? = null
        private var current: State? = null

        /** New player state from Dart: starts the service on the first track, otherwise refreshes it in place. */
        fun update(context: Context, args: Map<*, *>) {
            val artPath = args["artPath"] as? String
            val previous = current
            current = State(
                title = args["title"] as? String ?: "",
                artist = args["artist"] as? String ?: "",
                artPath = artPath,
                art = if (artPath == previous?.artPath) previous?.art else artPath?.let(BitmapFactory::decodeFile),
                playing = args["playing"] as? Boolean ?: false,
                position = (args["position"] as? Number)?.toLong() ?: 0L,
                duration = (args["duration"] as? Number)?.toLong() ?: 0L,
                speed = (args["speed"] as? Number)?.toFloat() ?: 1f,
            )
            // Refreshing a running service in place avoids Android 12+'s ban on foreground starts from the background.
            val service = instance
            if (service != null) {
                service.render()
                return
            }
            try {
                context.startForegroundService(Intent(context, MusicService::class.java))
            } catch (error: RuntimeException) {
                Log.w(TAG, "music service not started: $error")
            }
        }

        fun stop(context: Context) {
            current = null
            context.stopService(Intent(context, MusicService::class.java))
        }
    }
}
