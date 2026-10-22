package com.appshub.bettbox.services

import android.Manifest
import android.app.AppOpsManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.appshub.bettbox.CompatibilityLaunchActivity
import com.appshub.bettbox.CompatibilityResumeReceiver
import com.appshub.bettbox.R
import com.appshub.bettbox.VpnRunIntentStore
import com.appshub.bettbox.plugins.VpnPlugin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.NetworkInterface
import java.util.concurrent.atomic.AtomicBoolean
import java.util.UUID

object CompatibilityAppManager {
    const val YADEA_PACKAGE = "com.yadea.smartmoto"
    const val EXTRA_TARGET_PACKAGE = "targetPackage"
    const val EXTRA_SHORTCUT_TOKEN = "shortcutToken"
    const val ACTION_RESUME = "com.appshub.bettbox.action.COMPATIBILITY_RESUME"
    const val ACTION_KEEP_STOPPED = "com.appshub.bettbox.action.COMPATIBILITY_KEEP_STOPPED"

    private const val TAG = "CompatibilityApp"
    private const val CHANNEL_ID = "compatibility_app"
    private const val NOTIFICATION_ID = 17041
    private const val PREFS_NAME = "compatibility_apps"
    private const val SHORTCUT_TOKEN_KEY = "yadea_shortcut_token"
    private const val AWAY_GRACE_MILLIS = 10_000L
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val active = AtomicBoolean(false)

    @Volatile private var pausedByCompatibility = false
    fun isPaused(): Boolean = active.get() && pausedByCompatibility

    fun canPostNotifications(context: Context): Boolean {
        val permissionGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!permissionGranted ||
            !NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            return false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = context.getSystemService(NotificationManager::class.java)
                ?.getNotificationChannel(CHANNEL_ID)
            if (channel?.importance == NotificationManager.IMPORTANCE_NONE) return false
        }
        return true
    }

    fun isInstalled(context: Context, packageName: String): Boolean = runCatching {
        context.packageManager.getApplicationInfo(packageName, 0)
        true
    }.getOrDefault(false)

    fun hasUsageAccess(context: Context): Boolean {
        val appOps = context.getSystemService(AppOpsManager::class.java) ?: return false
        return appOps.checkOpNoThrow(
            AppOpsManager.OPSTR_GET_USAGE_STATS,
            Process.myUid(),
            context.packageName,
        ) == AppOpsManager.MODE_ALLOWED
    }

    fun openUsageAccessSettings(context: Context): Boolean = runCatching {
        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).apply {
            data = Uri.parse("package:${context.packageName}")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
        true
    }.recoverCatching {
        context.startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        })
        true
    }.getOrDefault(false)

    private fun miuiLegacyShortcutIntent(context: Context): Intent =
        Intent("com.android.launcher.action.INSTALL_SHORTCUT").apply {
            setPackage("com.miui.home")
        }

    private fun supportsMiuiLegacyShortcut(context: Context): Boolean =
        context.packageManager.queryBroadcastReceivers(
            miuiLegacyShortcutIntent(context),
            0,
        ).isNotEmpty()

    fun isShortcutSupported(context: Context): Boolean =
        ShortcutManagerCompat.isRequestPinShortcutSupported(context) ||
            supportsMiuiLegacyShortcut(context)

    fun createPinnedShortcut(context: Context, packageName: String): Boolean {
        if (packageName != YADEA_PACKAGE || !isInstalled(context, packageName)) return false
        val pm = context.packageManager
        val appInfo = runCatching { pm.getApplicationInfo(packageName, 0) }.getOrNull()
            ?: return false
        val label = appInfo.loadLabel(pm).toString().ifBlank { "雅迪智行" }
        val drawable = runCatching { pm.getApplicationIcon(packageName) }.getOrNull()
            ?: return false
        val size = (108 * context.resources.displayMetrics.density).toInt().coerceAtLeast(108)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(Canvas(bitmap))
        val shortcutPrefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val savedToken = shortcutPrefs.getString(SHORTCUT_TOKEN_KEY, null)
            ?.takeIf { it.isNotBlank() }
        val token = savedToken ?: UUID.randomUUID().toString().also {
            if (!shortcutPrefs.edit().putString(SHORTCUT_TOKEN_KEY, it).commit()) return false
        }
        val intent = Intent(context, CompatibilityLaunchActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            putExtra(EXTRA_TARGET_PACKAGE, packageName)
            putExtra(EXTRA_SHORTCUT_TOKEN, token)
        }
        val shortcut = ShortcutInfoCompat.Builder(context, "compat-$packageName")
            .setShortLabel(label)
            .setLongLabel("无 VPN 打开 $label")
            .setIcon(IconCompat.createWithBitmap(bitmap))
            .setIntent(intent)
            .build()
        val legacyIntent = miuiLegacyShortcutIntent(context).apply {
            putExtra(Intent.EXTRA_SHORTCUT_INTENT, intent)
            putExtra(Intent.EXTRA_SHORTCUT_NAME, label)
            putExtra(Intent.EXTRA_SHORTCUT_ICON, bitmap)
            putExtra("duplicate", false)
        }

        // A pinned shortcut from an older SG build may carry no token, or a
        // token that predates the stable-token migration. Refresh it in place
        // before requesting another desktop icon.
        val shortcutId = "compat-$packageName"
        val alreadyPinned = runCatching {
            context.getSystemService(ShortcutManager::class.java)
                ?.pinnedShortcuts
                ?.any { it.id == shortcutId } == true
        }.getOrDefault(false)
        if (alreadyPinned && runCatching {
                ShortcutManagerCompat.updateShortcuts(context, listOf(shortcut))
            }.getOrDefault(false)) {
            return true
        }

        // HyperOS still advertises the legacy INSTALL_SHORTCUT receiver even
        // when the platform drops that broadcast. Prefer the supported modern
        // API, and keep the old broadcast only as a last-resort fallback.
        if (ShortcutManagerCompat.isRequestPinShortcutSupported(context) &&
            runCatching {
                ShortcutManagerCompat.requestPinShortcut(context, shortcut, null)
            }.getOrDefault(false)) {
            return true
        }
        val supportsMiuiLegacy = pm.queryBroadcastReceivers(legacyIntent, 0).isNotEmpty()
        if (supportsMiuiLegacy) {
            return runCatching {
                context.sendBroadcast(legacyIntent)
                true
            }.getOrDefault(false)
        }
        return false
    }

    fun launchFromShortcut(
        context: Context,
        packageName: String,
        token: String?,
    ): Boolean {
        val expected = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(SHORTCUT_TOKEN_KEY, null)
        if (expected.isNullOrBlank() || token != expected) return false
        return launchCompatible(context, packageName)
    }

    fun launchCompatible(context: Context, packageName: String): Boolean {
        if (packageName != YADEA_PACKAGE || !isInstalled(context, packageName)) return false
        if (!hasUsageAccess(context) && !canPostNotifications(context)) return false
        val launchIntent = context.packageManager.getLaunchIntentForPackage(packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            ?: return false
        if (!active.compareAndSet(false, true)) return false
        scope.launch {
            val paused = VpnPlugin.handleCompatibilityPause()
            pausedByCompatibility = paused
            if (paused) waitForVpnGone(context.applicationContext)
            try {
                withContext(Dispatchers.Main) {
                    context.applicationContext.startActivity(launchIntent)
                }
            } catch (error: Throwable) {
                Log.e(TAG, "target launch failed: ${error.javaClass.simpleName}")
                resumeNow(context.applicationContext)
                return@launch
            }
            if (!paused) {
                clearSession(context.applicationContext)
                return@launch
            }
            showResumeNotification(context.applicationContext)
            if (hasUsageAccess(context.applicationContext)) {
                monitorForeground(context.applicationContext, packageName)
            }
        }
        return true
    }

    fun resumeNow(context: Context): Boolean {
        val shouldResume = pausedByCompatibility &&
            VpnRunIntentStore.read(context.applicationContext) != false
        val resumed = shouldResume && VpnPlugin.handleCompatibilityResume()
        clearSession(context.applicationContext)
        return resumed
    }

    fun keepStopped(context: Context): Boolean {
        if (!active.get()) return false
        VpnRunIntentStore.write(context.applicationContext, false)
        VpnPlugin.setSmartStopped(false)
        VpnPlugin.handleStop(force = true)
        clearSession(context.applicationContext)
        return true
    }

    private suspend fun waitForVpnGone(context: Context) {
        repeat(60) {
            if (!isVpnVisible(context)) return
            delay(100)
        }
        Log.w(TAG, "VPN visibility did not clear before target launch timeout")
    }

    private fun isVpnVisible(context: Context): Boolean {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val transportVisible = connectivity?.allNetworks?.any { network ->
            connectivity.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        } == true
        val tunVisible = runCatching {
            NetworkInterface.getNetworkInterfaces().toList().any { iface ->
                iface.isUp && (iface.name == "tun0" || iface.name.startsWith("tun"))
            }
        }.getOrDefault(false)
        return transportVisible || tunVisible
    }

    private suspend fun monitorForeground(context: Context, target: String) {
        var targetSeen = false
        var awaySince: Long? = null
        while (active.get()) {
            if (!hasUsageAccess(context)) return
            val foreground = currentForegroundPackage(context)
            val transient = isTransientSystemUi(foreground)
            if (foreground == target) {
                targetSeen = true
                awaySince = null
            } else if (targetSeen && !transient && !foreground.isNullOrBlank()) {
                if (awaySince == null) awaySince = SystemClock.elapsedRealtime()
            } else if (transient) {
                awaySince = null
            }
            val awayDuration = awaySince?.let {
                SystemClock.elapsedRealtime() - it
            } ?: 0L
            val userWantsVpn = VpnRunIntentStore.read(context) != false
            if (CompatibilityAppPolicy.shouldResume(
                    pausedByCompatibility,
                    userWantsVpn,
                    targetSeen,
                    foreground,
                    target,
                    transient,
                    awayDuration,
                    AWAY_GRACE_MILLIS,
                )) {
                resumeNow(context)
                return
            }
            if (!userWantsVpn) {
                clearSession(context)
                return
            }
            delay(1_000)
        }
    }

    private fun currentForegroundPackage(context: Context): String? {
        val usage = context.getSystemService(UsageStatsManager::class.java) ?: return null
        val end = System.currentTimeMillis()
        val events = usage.queryEvents(end - 60_000, end)
        val event = UsageEvents.Event()
        var latestPackage: String? = null
        var latestTime = Long.MIN_VALUE
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            val foregroundEvent = event.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND ||
                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                    event.eventType == UsageEvents.Event.ACTIVITY_RESUMED)
            if (foregroundEvent && event.timeStamp >= latestTime) {
                latestPackage = event.packageName
                latestTime = event.timeStamp
            }
        }
        return latestPackage
    }

    private fun isTransientSystemUi(packageName: String?): Boolean = packageName in setOf(
        "com.android.settings",
        "com.android.permissioncontroller",
        "com.google.android.permissioncontroller",
        "com.android.systemui",
        "com.miui.securitycenter",
    )

    private fun showResumeNotification(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel(
                CHANNEL_ID,
                "兼容应用",
                NotificationManager.IMPORTANCE_DEFAULT,
            ))
        }
        val resumeIntent = Intent(context, CompatibilityResumeReceiver::class.java).apply {
            action = ACTION_RESUME
        }
        val stopIntent = Intent(context, CompatibilityResumeReceiver::class.java).apply {
            action = ACTION_KEEP_STOPPED
        }
        val pending = PendingIntent.getBroadcast(
            context,
            0,
            resumeIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopPending = PendingIntent.getBroadcast(
            context,
            1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val auto = hasUsageAccess(context)
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_tile)
            .setContentTitle("雅迪兼容模式")
            .setContentText(if (auto)
                "Bettbox 已暂停，离开雅迪后自动恢复"
            else
                "Bettbox 已暂停，用完雅迪后请点击恢复")
            .setOngoing(true)
            .setAutoCancel(false)
            .addAction(0, "立即恢复 Bettbox", pending)
            .addAction(0, "保持停止", stopPending)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
    }

    private fun clearSession(context: Context) {
        active.set(false)
        pausedByCompatibility = false
        context.getSystemService(NotificationManager::class.java)
            ?.cancel(NOTIFICATION_ID)
    }
}
