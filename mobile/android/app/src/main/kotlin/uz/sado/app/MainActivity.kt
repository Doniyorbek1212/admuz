package uz.sado.app

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

class MainActivity : FlutterActivity() {
    // The engine lives in MainApplication and outlives this activity (FlutterActivity keeps host-provided engines).
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(MainApplication.ENGINE_ID)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        askBatteryExemptionOnce()
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
}
