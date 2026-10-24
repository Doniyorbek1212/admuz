package uz.sado.app

import android.app.Application
import android.os.BatteryManager
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
                // Power saving mode turns on below a chosen battery level.
                "batteryLevel" -> result.success(
                    getSystemService(BatteryManager::class.java)?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY),
                )
                else -> result.notImplemented()
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, VideoNoteTranscoder.CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "cropSquare" -> {
                    val input = call.argument<String>("input")
                    val output = call.argument<String>("output")
                    val size = call.argument<Int>("size") ?: 480
                    if (input == null || output == null) {
                        result.error("bad_args", "input and output are required", null)
                    } else {
                        VideoNoteTranscoder.cropSquare(this, input, output, size, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
        val music = MethodChannel(engine.dartExecutor.binaryMessenger, MusicService.CHANNEL)
        MusicService.channel = music
        music.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    MusicService.update(this, call.arguments as? Map<*, *> ?: emptyMap<String, Any>())
                    result.success(null)
                }
                "stop" -> {
                    MusicService.stop(this)
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
