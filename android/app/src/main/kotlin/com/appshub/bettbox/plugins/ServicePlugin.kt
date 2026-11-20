package com.appshub.bettbox.plugins

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.appshub.bettbox.BettboxApplication
import com.appshub.bettbox.GlobalState
import com.appshub.bettbox.RunState
import com.appshub.bettbox.models.VpnOptions
import com.appshub.bettbox.services.CompatibilityAppManager
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CopyOnWriteArrayList

class ServicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel

    companion object {
        private val activeChannels = CopyOnWriteArrayList<MethodChannel>()
        private val mainHandler = Handler(Looper.getMainLooper())
        private val gson = Gson()
        private const val TAG = "ServicePlugin"

        private fun notify(method: String, arguments: Any? = null) {
            mainHandler.post {
                activeChannels.forEach { ch ->
                    runCatching { ch.invokeMethod(method, arguments) }
                        .onFailure { Log.e(TAG, "$method notify error: ${it.message}") }
                }
            }
        }

        fun notifyNetworkChanged() = notify("networkChanged")
        fun notifySmartNetworkChanged() = notify("networkChanged", mapOf("smartNetworkOnly" to true))
        fun notifyQuickResponse() = notify("quickResponse")
        fun notifyVpnStartFailed() = notify("vpnStartFailed")
        fun notifyScreenStateChanged(isOn: Boolean) = notify("screenStateChanged", isOn)
        fun notifyRunStateChanged(state: RunState) {
            mainHandler.post {
                activeChannels.forEach { ch ->
                    runCatching { ch.invokeMethod("runStateChanged", state.name) }
                        .onFailure { Log.e(TAG, "runStateChanged notify error: ${it.message}") }
                }
            }
        }
    }

    private fun notifyNotebookSwitch(group: String?, selected: String?): Boolean {
        if (group.isNullOrBlank() || selected.isNullOrBlank()) return false
        val context = BettboxApplication.getAppContext()
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return false
        val channelId = "notebook_switch"
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.getSystemService(NotificationManager::class.java)?.createNotificationChannel(
                    NotificationChannel(channelId, "Notebook", NotificationManager.IMPORTANCE_DEFAULT),
                )
            }
            val notification = NotificationCompat.Builder(context, channelId)
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentTitle("Notebook · $group")
                .setContentText(selected)
                .setAutoCancel(true)
                .build()
            manager.notify("notebook:$group", 1, notification)
            true
        }.getOrDefault(false)
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "service").apply {
            setMethodCallHandler(this@ServicePlugin)
        }
        activeChannels.add(channel)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        activeChannels.remove(channel)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startVpn" -> handleStartVpn(call, result)
            "stopVpn" -> {
                VpnPlugin.handleStop(force = true)
                result.success(true)
            }
            "smartStop" -> {
                VpnPlugin.handleSmartStop()
                result.success(true)
            }
            "smartResume" -> {
                val data = call.argument<String>("data")
                val options = gson.fromJson(data, VpnOptions::class.java)
                VpnPlugin.handleSmartResume(options)
                result.success(true)
            }
            "setSmartStopped" -> {
                VpnPlugin.setSmartStopped(call.argument<Boolean>("value") ?: false)
                result.success(true)
            }
            "isSmartStopped" -> result.success(GlobalState.isSmartStopped)
            "isCompatibilityPaused" -> result.success(
                CompatibilityAppManager.isPaused(),
            )
            "getLocalIpAddresses" -> result.success(VpnPlugin.getLocalIpAddresses())
            "getLocalGateways" -> result.success(VpnPlugin.getLocalGateways())
            "getNetworkInfo" -> result.success(VpnPlugin.getNetworkInfo())
            "getSmartNetworkSnapshot" -> result.success(VpnPlugin.getSmartNetworkSnapshot())
            "resumeCore" -> {
                VpnPlugin.resumeCore { result.success(true) }
            }
            "checkSmartAutoStop", "requestSmartAutoStopCheck" -> {
                VpnPlugin.requestSmartAutoStopCheck()
                result.success(true)
            }
            "getCurrentDns" -> result.success(VpnPlugin.getCurrentDns())
            "notifyNotebookSwitch" -> result.success(
                notifyNotebookSwitch(call.argument<String>("group"), call.argument<String>("selected")),
            )
            "setQuickResponse" -> {
                VpnPlugin.setQuickResponse(call.argument<Boolean>("enabled") ?: false)
                result.success(true)
            }
            "init" -> {
                GlobalState.getCurrentAppPlugin()?.requestNotificationsPermission()
                GlobalState.initServiceEngine()
                result.success(true)
            }
            "isServiceEngineRunning" -> result.success(GlobalState.isServiceEngineRunning())
            "status" -> result.success(GlobalState.currentRunState == RunState.START)
            "reconnectIpc" -> {
                GlobalState.reconnectIpc()
                result.success(true)
            }
            "destroy" -> {
                GlobalState.destroyServiceEngine()
                result.success(true)
            }
            "updateNotificationSpeed" -> {
                VpnPlugin.handleUpdateNotificationSpeed(
                    call.argument<String>("profileName") ?: "",
                    call.argument<String>("speedInfo") ?: ""
                )
                result.success(true)
            }
            "restoreNotification" -> {
                GlobalState.isSpeedNotificationEnabled = false
                VpnPlugin.restoreNotification()
                result.success(true)
            }
            "setHighPriorityNotification" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                VpnPlugin.setHighPriorityNotification(enabled)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleStartVpn(call: MethodCall, result: MethodChannel.Result) {
        val data = call.argument<String>("data")
        if (data.isNullOrBlank() || data == "null") {
            result.error("INVALID_ARGUMENT", "options data is null", null)
            return
        }
        runCatching { gson.fromJson(data, VpnOptions::class.java) }
            .onSuccess { options ->
                result.success(VpnPlugin.handleStart(
                    options, call.argument<Boolean>("overrideSmartStop") == true,
                ))
            }
            .onFailure { result.error("PARSE_ERROR", it.message, null) }
    }
}
