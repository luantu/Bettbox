package com.appshub.bettbox

import android.app.Activity
import android.os.Bundle
import android.widget.Toast
import com.appshub.bettbox.services.CompatibilityAppManager

class CompatibilityLaunchActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val target = intent.getStringExtra(CompatibilityAppManager.EXTRA_TARGET_PACKAGE)
        val token = intent.getStringExtra(CompatibilityAppManager.EXTRA_SHORTCUT_TOKEN)
        val accepted = target != null &&
            CompatibilityAppManager.launchFromShortcut(this, target, token)
        if (!accepted) {
            Toast.makeText(this, "无法启动雅迪兼容模式", Toast.LENGTH_SHORT).show()
            finishAndRemoveTask()
            return
        }
        // Keep this transparent user-initiated activity alive until the target
        // launch is dispatched, so Android does not classify it as a blocked
        // background activity start while TUN is being removed.
        window.decorView.postDelayed({ finishAndRemoveTask() }, 8_000)
    }
}
