package com.appshub.bettbox

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.appshub.bettbox.services.CompatibilityAppManager

class CompatibilityResumeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == CompatibilityAppManager.ACTION_RESUME) {
            CompatibilityAppManager.resumeNow(context)
        }
    }
}
