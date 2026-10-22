package uz.sado.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Wakes the process after a reboot or an app update; [MainApplication] then starts the engine and the keep-alive service. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (KeepAliveService.isEnabled(context)) KeepAliveService.start(context)
    }
}
