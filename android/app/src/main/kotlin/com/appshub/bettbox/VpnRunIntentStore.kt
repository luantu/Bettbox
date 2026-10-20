package com.appshub.bettbox

import android.content.Context

object VpnRunIntentStore {
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val RUN_INTENT_KEY = "flutter.is_vpn_running"

    fun read(context: Context): Boolean? {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return if (prefs.contains(RUN_INTENT_KEY)) {
            prefs.getBoolean(RUN_INTENT_KEY, false)
        } else {
            null
        }
    }

    fun write(context: Context, wanted: Boolean) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(RUN_INTENT_KEY, wanted)
            .commit()
    }

    fun allowsAutomaticStart(context: Context): Boolean = read(context) != false
}
