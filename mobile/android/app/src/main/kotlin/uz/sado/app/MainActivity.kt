package uz.sado.app

import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
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
    private var callChannel: MethodChannel? = null
    private var callPip = false
    private var callPipRatio = Rational(1, 1)
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
                        // Hub quick links open the service's own app when installed; false lets Dart open the website.
                        "openApp" -> {
                            // Any launcher app is visible through the manifest's MAIN/LAUNCHER <queries> entry, so admin-added apps work too.
                            val launch = call.argument<String>("package")?.let { packageManager.getLaunchIntentForPackage(it) }
                            val opened = launch != null && runCatching { startActivity(launch) }.isSuccess
                            result.success(opened)
                        }
                        // Apps on the phone the user can pin to the hub: [{package, label}] by name. Labels load slowly, so off the UI thread.
                        "installedApps" -> Thread {
                            val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                            val apps = packageManager.queryIntentActivities(launcher, 0)
                                .filter { it.activityInfo.packageName != packageName }
                                .distinctBy { it.activityInfo.packageName }
                                .map { mapOf("package" to it.activityInfo.packageName, "label" to it.loadLabel(packageManager).toString()) }
                                .sortedBy { it["label"]?.lowercase() }
                            runOnUiThread { result.success(apps) }
                        }.start()
                        // An app's launcher icon as PNG bytes (null when it is gone).
                        "appIcon" -> Thread {
                            val png = call.argument<String>("package")?.let { pkg ->
                                runCatching {
                                    val icon = packageManager.getApplicationIcon(pkg)
                                    val bitmap = android.graphics.Bitmap.createBitmap(APP_ICON_PX, APP_ICON_PX, android.graphics.Bitmap.Config.ARGB_8888)
                                    icon.setBounds(0, 0, APP_ICON_PX, APP_ICON_PX)
                                    icon.draw(android.graphics.Canvas(bitmap))
                                    java.io.ByteArrayOutputStream().also { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
                                }.getOrNull()
                            }
                            runOnUiThread { result.success(png) }
                        }.start()
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
        // Calls: the ongoing-call service, and a floating window (picture-in-picture) when the user leaves mid-call.
        callChannel = flutterEngine?.let { engine ->
            MethodChannel(engine.dartExecutor.binaryMessenger, CALL_CHANNEL).apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "update" -> {
                            val active = call.argument<Boolean>("active") == true
                            val video = call.argument<Boolean>("video") == true
                            callPipRatio = if (video) Rational(9, 16) else Rational(1, 1)
                            callPip = active
                            if (active) {
                                OngoingCallService.start(
                                    this@MainActivity,
                                    call.argument<String>("title").orEmpty(),
                                    call.argument<String>("text").orEmpty(),
                                    call.argument<Number>("since")?.toLong() ?: 0L,
                                    video,
                                )
                            } else {
                                OngoingCallService.stop(this@MainActivity)
                                // The call ended in the floating window: close it like Telegram does, not leave the app shrunk.
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode) moveTaskToBack(false)
                            }
                            applyCallAutoPip()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        }
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

    /** Android 12+: the system itself shrinks the call into a floating window on Home / app switch. */
    private fun applyCallAutoPip() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        runCatching {
            setPictureInPictureParams(PictureInPictureParams.Builder().setAutoEnterEnabled(callPip).setAspectRatio(callPipRatio).build())
        }
    }

    // Android 8-11: no auto-enter, so the call enters the floating window when the user leaves with Home.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (callPip && Build.VERSION.SDK_INT in Build.VERSION_CODES.O until Build.VERSION_CODES.S) {
            enterPip(callPipRatio.numerator, callPipRatio.denominator)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // The ongoing-call notification: show the call screen again.
        if (intent.getBooleanExtra(EXTRA_OPEN_CALL, false)) callChannel?.invokeMethod("open", null)
    }

    override fun onDestroy() {
        callChannel?.setMethodCallHandler(null)
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
        callChannel?.invokeMethod("pip", isInPictureInPictureMode)
    }

    override fun onResume() {
        super.onResume()
        // Foreground starts are always allowed here; covers a start refused while the app was in the background.
        if (KeepAliveService.isEnabled(this)) KeepAliveService.start(this)
        // The call notification tapped after this activity was destroyed (the call service kept the engine):
        // onNewIntent does not run then, so the extra arrives with the launch intent. Read once.
        if (intent?.getBooleanExtra(EXTRA_OPEN_CALL, false) == true) {
            intent.removeExtra(EXTRA_OPEN_CALL)
            callChannel?.invokeMethod("open", null)
        }
    }

    companion object {
        const val PIP_CHANNEL = "uz.sado.app/pip"
        const val CALL_CHANNEL = "uz.sado.app/call"
        const val EXTRA_OPEN_CALL = "uz.sado.app.OPEN_CALL"
        const val PRIVACY_CHANNEL = "uz.sado.app/privacy"
        // Hub quick-link tiles are 58dp: 144px stays sharp up to ~2.5x screens.
        private const val APP_ICON_PX = 144
        private const val THUMB_MAX_SIDE = 320

        // Process-wide like the cached engine: a recreated activity (rotation) keeps the flag Dart last sent.
        @Volatile
        private var secureWindow = false
    }
}
