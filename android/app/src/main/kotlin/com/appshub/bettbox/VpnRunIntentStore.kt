package com.appshub.bettbox

import android.content.Context

object VpnRunIntentStore {
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val USER_RUN_INTENT_KEY = "flutter.vpn_user_run_intent"
    private const val USER_RUN_INTENT_MIGRATED_KEY = "flutter.vpn_user_run_intent_migrated"

    fun read(context: Context): Boolean? {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (prefs.contains(USER_RUN_INTENT_KEY)) {
            return prefs.getBoolean(USER_RUN_INTENT_KEY, false)
        }
        if (prefs.getBoolean(USER_RUN_INTENT_MIGRATED_KEY, false)) return null
        // The old runtime key was also cleared by failures and internal
        // restarts. Never promote it to an explicit user choice.
        prefs.edit().putBoolean(USER_RUN_INTENT_MIGRATED_KEY, true).commit()
        return null
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
