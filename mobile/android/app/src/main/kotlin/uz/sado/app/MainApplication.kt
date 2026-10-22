package uz.sado.app

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Runs the Flutter engine with the process instead of the activity. Closing the UI no longer stops
 * Dart, so TDLib stays connected and keeps posting message notifications while [KeepAliveService]
 * holds the process; after a reboot or a kill the service brings the engine back without any UI.
 */
class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this)
        MethodChannel(engine.dartExecutor.binaryMessenger, KeepAliveService.CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    KeepAliveService.setEnabled(this, call.arguments as? Boolean ?: true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        if (KeepAliveService.isEnabled(this)) KeepAliveService.start(this)
    }

    companion object {
        const val ENGINE_ID = "main"
    }
}
