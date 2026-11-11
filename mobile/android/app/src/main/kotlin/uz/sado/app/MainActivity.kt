package uz.sado.app

import android.annotation.SuppressLint
import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Rational
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // The engine lives in MainApplication and outlives this activity (FlutterActivity keeps host-provided engines).
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(MainApplication.ENGINE_ID)

    private var pipChannel: MethodChannel? = null
    private var privacyChannel: MethodChannel? = null
    private var tone: android.media.Ringtone? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applySecureWindow()
        // Passcode on: FLAG_SECURE hides the chats from the recents thumbnail and from screenshots/recording.
        privacyChannel = flutterEngine?.let { engine ->
            MethodChannel(engine.dartExecutor.binaryMessenger, PRIVACY_CHANNEL).apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "setSecure" -> {
                            secureWindow = call.argument<Boolean>("enabled") == true
                            applySecureWindow()
                            result.success(null)
                        }
                        // Gift shows stay quiet when the phone is on silent or vibrate.
                        "isSilent" -> result.success(
                            (getSystemService(Context.AUDIO_SERVICE) as? android.media.AudioManager)
                                ?.ringerMode?.let { it != android.media.AudioManager.RINGER_MODE_NORMAL } ?: false
                        )
                        // MIUI silences notifications of the app on screen, so the app plays the
                        // message tone itself: tone_<id> from res/raw, or the phone's default.
                        // Notification attributes: silent/vibrate mode and the notification volume apply.
                        "playTone" -> {
                            val name = call.argument<String>("name")
                            val uri = if (name == null) {
                                android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_NOTIFICATION)
                            } else {
                                Uri.parse("android.resource://$packageName/raw/$name")
                            }
                            tone?.stop()
                            tone = android.media.RingtoneManager.getRingtone(this@MainActivity, uri)?.apply {
                                audioAttributes = android.media.AudioAttributes.Builder()
                                    .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION_COMMUNICATION_INSTANT)
                                    .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                    .build()
                                play()
                            }
                            result.success(null)
                        }
                        // Cover of an outgoing video: without one receivers (and reply quotes) see a grey box.
                        "videoThumbnail" -> {
                            val path = call.argument<String>("path")
                            if (path == null) {
                                result.success(null)
                            } else {
                                Thread {
                                    val thumb = videoThumbnail(path)
                                    runOnUiThread { result.success(thumb) }
                                }.start()
                            }
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        }
        askBatteryExemptionOnce()
        // Picture-in-picture for the video viewer ("Kichraytirish"); Dart learns about mode changes over the same channel.
        pipChannel = flutterEngine?.let { engine ->
            MethodChannel(engine.dartExecutor.binaryMessenger, PIP_CHANNEL).apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "enter" -> result.success(enterPip(call.argument<Int>("width") ?: 16, call.argument<Int>("height") ?: 9))
                        else -> result.notImplemented()
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        pipChannel?.setMethodCallHandler(null)
        privacyChannel?.setMethodCallHandler(null)
        super.onDestroy()
    }

    /** First frame of a video as a JPEG of at most 320px (Telegram's thumbnail limit); null when it cannot be read. */
    private fun videoThumbnail(path: String): Map<String, Any>? {
        val retriever = android.media.MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val frame = retriever.getFrameAtTime(0, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: return null
            val scale = minOf(1f, THUMB_MAX_SIDE.toFloat() / maxOf(frame.width, frame.height))
            val width = (frame.width * scale).toInt().coerceAtLeast(1)
            val height = (frame.height * scale).toInt().coerceAtLeast(1)
            val scaled = android.graphics.Bitmap.createScaledBitmap(frame, width, height, true)
            val dir = java.io.File(cacheDir, "video_thumbs").apply { mkdirs() }
            val out = java.io.File(dir, "${path.hashCode()}_${java.io.File(path).lastModified()}.jpg")
            out.outputStream().use { scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, it) }
            if (scaled !== frame) scaled.recycle()
            frame.recycle()
            mapOf("path" to out.absolutePath, "width" to width, "height" to height)
        } catch (error: RuntimeException) {
            null
        } catch (error: java.io.IOException) {
            null
        } finally {
            retriever.release()
        }
    }

    private fun applySecureWindow() {
        if (secureWindow) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    private fun enterPip(width: Int, height: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        // Android only accepts aspect ratios between 1:2.39 and 2.39:1.
        val ratio = (width.toDouble() / height.coerceAtLeast(1)).coerceIn(1 / 2.39, 2.39)
        val params = PictureInPictureParams.Builder().setAspectRatio(Rational((ratio * 1000).toInt(), 1000)).build()
        return try {
            enterPictureInPictureMode(params)
        } catch (error: IllegalStateException) {
            false
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("changed", isInPictureInPictureMode)
    }

    override fun onResume() {
        super.onResume()
        // Foreground starts are always allowed here; covers a start refused while the app was in the background.
        if (KeepAliveService.isEnabled(this)) KeepAliveService.start(this)
    }

    /** Battery optimisation kills background connections (aggressively on MIUI); ask once to be exempt. */
    @SuppressLint("BatteryLife")
    private fun askBatteryExemptionOnce() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val prefs = getSharedPreferences("uz.sado.native", MODE_PRIVATE)
        if (prefs.getBoolean("askedBattery", false)) return
        prefs.edit().putBoolean("askedBattery", true).apply()
        val power = getSystemService(PowerManager::class.java)
        if (power.isIgnoringBatteryOptimizations(packageName)) return
        try {
            startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
        } catch (error: RuntimeException) {
            // Some ROMs hide this screen; the keep-alive service still runs, just less reliably.
        }
    }

    companion object {
        const val PIP_CHANNEL = "uz.sado.app/pip"
        const val PRIVACY_CHANNEL = "uz.sado.app/privacy"
        private const val THUMB_MAX_SIDE = 320

        // Process-wide like the cached engine: a recreated activity (rotation) keeps the flag Dart last sent.
        @Volatile
        private var secureWindow = false
    }
}
