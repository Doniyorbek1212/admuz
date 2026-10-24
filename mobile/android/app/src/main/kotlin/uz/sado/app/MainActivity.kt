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
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // The engine lives in MainApplication and outlives this activity (FlutterActivity keeps host-provided engines).
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(MainApplication.ENGINE_ID)

    private var pipChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
        super.onDestroy()
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
    }
}
