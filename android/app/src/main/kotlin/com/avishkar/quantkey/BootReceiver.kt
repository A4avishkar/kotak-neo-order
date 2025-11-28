package com.avishkar.quantkey

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || 
            intent.action == "android.intent.action.QUICKBOOT_POWERON") {
            // Check if background service was enabled before reboot
            val prefs: SharedPreferences = context.getSharedPreferences(
                "flutter.background_service_enabled", 
                Context.MODE_PRIVATE
            )
            val wasEnabled = prefs.getBoolean("background_service_enabled", false)
            
            if (wasEnabled) {
                // Service will be restarted when app initializes
                // The Flutter app's main.dart will call BackgroundDownloadService.initialize()
                // and if the service was enabled, it will start automatically
            }
        }
    }
}

