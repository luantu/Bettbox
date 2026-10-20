package com.appshub.bettbox

import android.content.Context

object VpnRunIntentStore {
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val USER_RUN_INTENT_KEY = "flutter.vpn_user_run_intent"
    private const val USER_RUN_INTENT_MIGRATED_KEY = "flutter.vpn_user_run_intent_migrated"
    private const val LEGACY_RUNTIME_KEY = "flutter.is_vpn_running"

    fun read(context: Context): Boolean? {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (prefs.contains(USER_RUN_INTENT_KEY)) {
            return prefs.getBoolean(USER_RUN_INTENT_KEY, false)
        }
        if (prefs.getBoolean(USER_RUN_INTENT_MIGRATED_KEY, false)) return null
        val migrated = if (prefs.contains(LEGACY_RUNTIME_KEY)) {
            prefs.getBoolean(LEGACY_RUNTIME_KEY, false)
        } else null
        val editor = prefs.edit().putBoolean(USER_RUN_INTENT_MIGRATED_KEY, true)
        if (migrated != null) editor.putBoolean(USER_RUN_INTENT_KEY, migrated)
        editor.commit()
        return migrated
    }

    fun write(context: Context, wanted: Boolean) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(USER_RUN_INTENT_KEY, wanted)
            .putBoolean(USER_RUN_INTENT_MIGRATED_KEY, true)
            .commit()
    }

    fun allowsAutomaticStart(context: Context): Boolean = read(context) != false
}
