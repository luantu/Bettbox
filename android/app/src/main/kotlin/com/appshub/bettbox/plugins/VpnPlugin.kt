package com.appshub.bettbox.plugins

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.widget.Toast
import androidx.core.content.getSystemService
import com.appshub.bettbox.BettboxApplication
import com.appshub.bettbox.GlobalState
import com.appshub.bettbox.RunState
import com.appshub.bettbox.core.Core
import com.appshub.bettbox.extensions.awaitResult
import com.appshub.bettbox.extensions.asSocketAddressText
import com.appshub.bettbox.extensions.resolveDns
import com.appshub.bettbox.models.StartForegroundParams
import com.appshub.bettbox.models.VpnOptions
import com.appshub.bettbox.modules.SuspendModule
import com.appshub.bettbox.services.BaseServiceInterface
import com.appshub.bettbox.services.BettboxService
import com.appshub.bettbox.services.BettboxVpnService
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import java.util.Collections
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock as withCoroutineLock
import java.net.InetSocketAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.withLock

data object VpnPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    @Volatile
    private var bettBoxService: BaseServiceInterface? = null
    @Volatile
    private var options: VpnOptions? = null

    @Volatile
    private var isBind = false
    private val isBinding = AtomicBoolean(false)
    private val bindingLock = Any()
    @Volatile private var pendingBindRequest: NativeRecoveryPolicy.BindRequest? = null

    private var job = SupervisorJob()
    private var scope = CoroutineScope(Dispatchers.Default + job as kotlin.coroutines.CoroutineContext)
    private var lastStartForegroundParams: StartForegroundParams? = null
    private val uidPageNameMap = ConcurrentHashMap<Int, String>()
    private var suspendModule: SuspendModule? = null

    @Volatile
    private var quickResponseEnabled = false
    private var quickResponseJob: Job? = null
    private val nativeRecoveryPolicy = NativeRecoveryPolicy()
    private val coreStartInFlight = AtomicBoolean(false)
    private val coreStartMutex = Mutex()
    @Volatile private var nativeRecoveryJob: Job? = null
    private val networkChangeLock = Any()
    private var networkBaselineReady = false
    private var lastUnderlyingNetwork: Network? = null
    private var lastDns = ""

    val networks: MutableSet<Network> = Collections.newSetFromMap(ConcurrentHashMap())

    private val connectivity by lazy {
        BettboxApplication.getAppContext().getSystemService<ConnectivityManager>()
    }

    private var bindTimeoutJob: Job? = null
    private val attachedMessengers = Collections.newSetFromMap(ConcurrentHashMap<BinaryMessenger, Boolean>())
    private val channelMap = ConcurrentHashMap<BinaryMessenger, MethodChannel>()
    private val activeChannels = CopyOnWriteArrayList<MethodChannel>()
    private val networkCallbackRegistered = AtomicBoolean(false)

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(className: ComponentName, service: IBinder) {
            var accepted = false
            val request = synchronized(bindingLock) {
                val pending = pendingBindRequest
                pendingBindRequest = null
                isBinding.set(false)
                if (pending != null && nativeRecoveryPolicy.isEpochCurrent(pending.intentEpoch) &&
                    !GlobalState.isCurrentlyStopping()) {
                    isBind = true
                    bettBoxService = when (service) {
                        is BettboxVpnService.LocalBinder -> service.getService()
                        is BettboxService.LocalBinder -> service.getService()
                        else -> throw Exception("invalid binder")
                    }
                    accepted = true
                }
                pending
            }
            bindTimeoutJob?.cancel()
            bindTimeoutJob = null
            if (!accepted) {
                runCatching { BettboxApplication.getAppContext().unbindService(this) }
                return
            }
            // Automatic binds only restore the service reference. The watchdog
            // retries with a fresh token and rechecks actual native readiness.
            if (request != null && nativeRecoveryPolicy.shouldStartAfterBind(
                    request.intentEpoch, request.automatic,
                    GlobalState.isSmartStopped, GlobalState.isCurrentlyStopping())) {
                handleStartService(request.intentEpoch)
            }
        }

        override fun onServiceDisconnected(arg: ComponentName) {
            isBind = false
            isBinding.set(false)
            bettBoxService = null
            if (GlobalState.currentRunState == RunState.START) {
                android.util.Log.w("VpnPlugin", "Service unexpectedly disconnected while running, syncing state")
                GlobalState.updateRunState(RunState.STOP)
                ServicePlugin.notifyVpnStartFailed()
                ServicePlugin.notifyRunStateChanged(RunState.STOP)
            }
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        val isFirstAttach = attachedMessengers.isEmpty()
        attachedMessengers.add(flutterPluginBinding.binaryMessenger)

        if (job.isCancelled) {
            job = SupervisorJob()
            scope = CoroutineScope(Dispatchers.Default + job as kotlin.coroutines.CoroutineContext)
        }

        val channel = MethodChannel(flutterPluginBinding.binaryMessenger, "vpn")
        channel.setMethodCallHandler(this)
        channelMap[flutterPluginBinding.binaryMessenger] = channel
        activeChannels.add(channel)

        if (isFirstAttach) {
            scope.launch { registerNetworkCallback() }
            if (nativeRecoveryPolicy.isWanted) startNativeRecoveryWatchdog()
        }

        scope.launch {
            var dns = when {
                lastDns.isNotBlank() -> lastDns
                else -> getCurrentDns()
            }
            if (dns.isBlank()) {
                delay(1000)
                dns = getCurrentDns()
                if (dns.isNotBlank()) lastDns = dns
            }
            withContext(Dispatchers.Main) {
                runCatching {
                    channel.invokeMethod("dnsChanged", dns)
                }
            }
        }

        if (GlobalState.currentRunState == RunState.START && bettBoxService == null) {
            android.util.Log.d("VpnPlugin", "VPN is running but service connection lost, rebinding...")
            options?.let { bindService(automatic = it.enable) }
        }
    }

    override fun onDetachedFromEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        attachedMessengers.remove(flutterPluginBinding.binaryMessenger)
        channelMap.remove(flutterPluginBinding.binaryMessenger)?.let { channel ->
            channel.setMethodCallHandler(null)
            activeChannels.remove(channel)
        }

        if (attachedMessengers.isEmpty()) {
            nativeRecoveryJob?.cancel()
            nativeRecoveryJob = null
            unRegisterNetworkCallback()
            job.cancel()
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                try {
                    val data = call.argument<String>("data")
                    if (data == null) {
                        result.error("INVALID_ARGUMENT", "data parameter is required", null)
                        return
                    }
                    val vpnOptions = Gson().fromJson(data, VpnOptions::class.java)
                    result.success(handleStart(vpnOptions))
                } catch (e: Exception) {
                    android.util.Log.e("VpnPlugin", "Failed to start VPN: ${e.message}")
                    result.error("PARSE_ERROR", "Failed to parse VpnOptions: ${e.message}", null)
                }
            }

            "stop" -> {
                handleStop()
                result.success(true)
            }

            "getLocalIpAddresses" -> {
                result.success(getLocalIpAddresses())
            }

            "resolveUnderlyingHost" -> {
                val host = call.argument<String>("host")?.trim().orEmpty()
                if (host.isBlank()) {
                    result.success(emptyList<String>())
                } else {
                    // VpnService.protect only bypasses VPN routing for a
                    // socket. Resolve the management hostname on the same
                    // physical Wi-Fi/cellular Network, not VPN fake-IP DNS.
                    scope.launch(Dispatchers.IO) {
                        val addresses = runCatching {
                            val physical = getActivePhysicalNetworks()
                            val active = connectivity?.activeNetwork
                            (selectedUnderlyingNetwork()
                                ?: active?.takeIf { physical.contains(it) }
                                ?: physical.firstOrNull())
                                ?.getAllByName(host)
                                ?.mapNotNull { it.hostAddress }
                                ?.filter { it.isNotBlank() }
                                ?: emptyList()
                        }.getOrElse { emptyList() }
                        withContext(Dispatchers.Main) {
                            result.success(addresses)
                        }
                    }
                }
            }

            "getLocalGateways" -> {
                result.success(getLocalGateways())
            }

            "setSmartStopped" -> {
                val value = call.argument<Boolean>("value") ?: false
                GlobalState.isSmartStopped = value
                result.success(true)
            }

            "isSmartStopped" -> {
                result.success(GlobalState.isSmartStopped)
            }

            "smartStop" -> {
                handleSmartStop()
                result.success(true)
            }

            "smartResume" -> {
                val data = call.argument<String>("data")
                result.success(handleSmartResume(Gson().fromJson(data, VpnOptions::class.java)))
            }
            
            "setQuickResponse" -> {
                quickResponseEnabled = call.argument<Boolean>("enabled") ?: false
                result.success(true)
            }

            "updateNotificationSpeed" -> {
                handleUpdateNotificationSpeed(
                    call.argument<String>("profileName") ?: "",
                    call.argument<String>("speedInfo") ?: ""
                )
                result.success(true)
            }

            "status" -> {
                result.success(GlobalState.currentRunState == RunState.START)
            }

            else -> {
                result.notImplemented()
            }
        }
    }
    
    fun setQuickResponse(enabled: Boolean) {
        quickResponseEnabled = enabled
    }

    private fun getActivePhysicalNetworks(): Set<Network> {
        val current = networks
        if (current.isNotEmpty()) return current

        val cm = connectivity ?: return emptySet()
        val isPhysical: (Network) -> Boolean = { net ->
            cm.getNetworkCapabilities(net)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == false
        }

        val available = cm.allNetworks.filter(isPhysical).toSet()
        if (available.isNotEmpty()) return available

        return cm.activeNetwork?.takeIf(isPhysical)?.let { setOf(it) } ?: emptySet()
    }

    fun getLocalIpAddresses(): List<String> = runCatching {
        getActivePhysicalNetworks().flatMap { network ->
            connectivity?.getLinkProperties(network)
                ?.linkAddresses
                ?.mapNotNull { it.address }
                ?.filter { !it.isLoopbackAddress && it.hostAddress?.contains(":") == false }
                ?.mapNotNull { it.hostAddress }
                ?: emptyList()
        }
    }.getOrElse {
        android.util.Log.e("VpnPlugin", "getLocalIpAddresses error: ${it.message}")
        emptyList()
    }

    fun getLocalGateways(): List<String> = runCatching {
        getActivePhysicalNetworks().flatMap { network ->
            connectivity?.getLinkProperties(network)
                ?.routes
                ?.filter { it.isDefaultRoute() }
                ?.mapNotNull { it.gateway }
                ?.filter {
                    !it.isLoopbackAddress && !it.isAnyLocalAddress &&
                        it.hostAddress?.contains(":") == false
                }
                ?.mapNotNull { it.hostAddress }
                ?: emptyList()
        }
    }.getOrElse {
        android.util.Log.e("VpnPlugin", "getLocalGateways error: ${it.message}")
        emptyList()
    }

    fun handleStart(options: VpnOptions): Boolean {
        onUpdateNetwork()
        if (options.enable != this.options?.enable) {
            this.bettBoxService = null
        }
        this.options = options
        nativeRecoveryPolicy.setWanted(options.enable)
        if (options.enable) startNativeRecoveryWatchdog()
        when (options.enable) {
            true -> handleStartVpn()
            false -> handleStartService()
        }
        return true
    }

    @Synchronized
    private fun startNativeRecoveryWatchdog() {
        if (nativeRecoveryJob?.isActive == true) return
        nativeRecoveryJob = scope.launch {
            while (isActive && nativeRecoveryPolicy.isWanted) {
                delay(2000)
                if (coreStartInFlight.get()) continue
                // Initial permission prompts belong to the user's normal start
                // flow. Background recovery must neither cancel nor replace it.
                if (runCatching {
                        android.net.VpnService.prepare(BettboxApplication.getAppContext()) != null
                    }.getOrDefault(true)) continue
                val token = runCatching {
                    nativeRecoveryPolicy.tryBegin(
                        android.os.SystemClock.elapsedRealtime(),
                        Core.nativeVpnRepairRequired(),
                        GlobalState.isSmartStopped,
                        GlobalState.isCurrentlyStopping(),
                        getActivePhysicalNetworks().isNotEmpty(),
                    )
                }.getOrNull() ?: continue
                try {
                    recoverNativeTransport(token)
                } catch (e: Exception) {
                    android.util.Log.w("VpnPlugin", "Native recovery failed: ${e.javaClass.simpleName}")
                } finally {
                    val ready = runCatching {
                        Core.androidTunReady() && !Core.nativeVpnRepairRequired()
                    }.getOrDefault(false)
                    nativeRecoveryPolicy.finish(token, android.os.SystemClock.elapsedRealtime(), ready)
                }
            }
        }
    }

    private suspend fun recoverNativeTransport(token: Long) {
        if (!nativeRecoveryPolicy.isCurrent(token) || coreStartInFlight.get()) return
        // This error can be a mode/admission mismatch, not a broken system TUN.
        // Reconcile only after Go verifies the actual listener/protect owner.
        if (Core.restoreNativeVpnAdmission()) {
            android.util.Log.i("VpnPlugin", "Native transport admission reconciled without TUN restart")
            return
        }
        val currentOptions = options?.takeIf { it.enable } ?: return
        if (bettBoxService == null) {
            bindService(automatic = true)
            return
        }
        if (android.net.VpnService.prepare(BettboxApplication.getAppContext()) != null) {
            // Revoked permission is not consent to bring up a background prompt.
            android.util.Log.w("VpnPlugin", "Native recovery stopped: VPN permission unavailable")
            handleStop(force = true)
            return
        }
        val allowed = GlobalState.runLock.withLock {
            if (!nativeRecoveryPolicy.isCurrent(token) || GlobalState.isSmartStopped ||
                GlobalState.isCurrentlyStopping()) false
            else {
                GlobalState.updateRunState(RunState.START)
                true
            }
        }
        if (!allowed) return
        android.util.Log.i("VpnPlugin", "Native transport unavailable; rebuilding native TUN")
        // A failed automatic attempt keeps running intent for bounded retries.
        // It must not send the UI's user-stop path or reauthorize the account.
        performStartCore(currentOptions, retry = true, notifyOnFailure = false, recoveryToken = token)
    }

    private fun handleStartVpn() {
        val intentEpoch = nativeRecoveryPolicy.intentEpoch
        GlobalState.getCurrentAppPlugin()?.requestVpnPermission {
            if (nativeRecoveryPolicy.isIntentCurrent(intentEpoch)) handleStartService(intentEpoch)
        }
    }

    fun requestGc() {
        invokeDart("gc")
    }

    fun onUpdateNetwork() {
        val dns = getCurrentDns()
        if (dns == lastDns) return
        lastDns = dns
        invokeDart("dnsChanged", dns)
    }

    fun notifyScreenStateChanged(isOn: Boolean) {
        invokeDart("screenStateChanged", isOn)
    }

    private fun getCurrentDns(): String {
        val dnsSet = when {
            networkDnsMap.isNotEmpty() -> networkDnsMap.values.flatMap { it }
            else -> {
                val cm = connectivity
                val activeNetwork = cm?.activeNetwork
                activeNetwork?.let { cm.resolveDns(it) } ?: emptyList()
            }
        }.toSet()
        return when {
            dnsSet.isNotEmpty() -> dnsSet.joinToString(",")
            else -> getAllNetworksDns()
        }
    }

    private fun getAllNetworksDns(): String {
        return runCatching {
            connectivity?.allNetworks?.flatMap { network ->
                connectivity?.resolveDns(network) ?: emptyList()
            }?.filter { it.isNotBlank() }?.toSet()?.joinToString(",") ?: ""
        }.getOrElse { "" }
    }

    private val networkDnsMap = ConcurrentHashMap<Network, List<String>>()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            networks.add(network)
            handleNetworkChange()
            invokeDart("networkChanged")
        }

        override fun onLost(network: Network) {
            networks.remove(network)
            networkDnsMap.remove(network)
            onUpdateNetwork()
            handleNetworkChange()
            invokeDart("networkChanged")
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            val dnsList = linkProperties.dnsServers.map { it.asSocketAddressText(53) }
            networkDnsMap[network] = dnsList
            onUpdateNetwork()
        }

        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
            // Capabilities can arrive after onAvailable. Re-evaluate the
            // physical network choice once Wi-Fi/cellular type is known.
            if (networks.contains(network) && handleNetworkChange()) {
                invokeDart("networkChanged")
            }
        }
    }

    private val request = NetworkRequest.Builder().apply {
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
    }.build()

    private fun registerNetworkCallback() {
        if (!networkCallbackRegistered.compareAndSet(false, true)) return
        runCatching {
            networks.clear()
            synchronized(networkChangeLock) {
                networkBaselineReady = false
                lastUnderlyingNetwork = null
            }
            connectivity?.registerNetworkCallback(request, callback)
        }.onFailure {
            networkCallbackRegistered.set(false)
            android.util.Log.e("VpnPlugin", "Failed to register network callback: ${it.message}")
        }
    }

    private fun unRegisterNetworkCallback() {
        if (!networkCallbackRegistered.compareAndSet(true, false)) return
        runCatching {
            connectivity?.unregisterNetworkCallback(callback)
        }.onFailure {
            android.util.Log.e("VpnPlugin", "Failed to unregister network callback: ${it.message}")
        }.also {
            networks.clear()
            networkDnsMap.clear()
            synchronized(networkChangeLock) {
                networkBaselineReady = false
                lastUnderlyingNetwork = null
            }
            onUpdateNetwork()
        }
    }
    
    private fun handleNetworkChange(): Boolean {
        val current = selectedUnderlyingNetwork()
        val changedWhileRunning = synchronized(networkChangeLock) {
            if (!networkBaselineReady) {
                networkBaselineReady = true
                lastUnderlyingNetwork = current
                false
            } else if (current == lastUnderlyingNetwork) {
                false
            } else {
                lastUnderlyingNetwork = current
                GlobalState.currentRunState == RunState.START
            }
        }
        if (!changedWhileRunning) return false

        // VPN becoming the system's activeNetwork does not change the
        // underlying Wi-Fi/cellular Network object, so it cannot reset a
        // healthy CorpLink TCP session. A Wi-Fi to Wi-Fi reconnect does.
        android.util.Log.i("VpnPlugin", "underlying network changed; reconnecting tunnels")
        ServicePlugin.notifyNetworkChanged()

        if (quickResponseEnabled) {
            quickResponseJob?.cancel()
            quickResponseJob = scope.launch {
                delay(150)
                if (GlobalState.currentRunState == RunState.START) {
                    ServicePlugin.notifyQuickResponse()
                }
            }
        }
        return true
    }

    private fun selectedUnderlyingNetwork(): Network? {
        val cm = connectivity ?: return null
        val active = cm.activeNetwork
        if (active != null && networks.contains(active)) return active
        return networks.maxWithOrNull(compareBy<Network> { network ->
                val caps = cm.getNetworkCapabilities(network)
                when {
                    caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true -> 3
                    caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true -> 2
                    caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true -> 1
                    else -> 0
                }
            }.thenBy { it.networkHandle })
    }

    private fun invokeDart(method: String, arguments: Any? = null) {
        if (activeChannels.isEmpty()) return
        scope.launch {
            withContext(Dispatchers.Main) {
                activeChannels.forEach { channel ->
                    runCatching { channel.invokeMethod(method, arguments) }
                        .onFailure {
                            android.util.Log.w("VpnPlugin", "invokeDart($method) failed: ${it.message}")
                        }
                }
            }
        }
    }
    
    private suspend fun startForeground() {
        val shouldUpdate = GlobalState.runLock.withLock {
            GlobalState.currentRunState == RunState.START || GlobalState.isSmartStopped
        }
        if (!shouldUpdate) return

        try {
            bettBoxService?.startForeground()
        } catch (e: Exception) {
            android.util.Log.e("VpnPlugin", "startForeground error: ${e.message}")
        }
    }

    fun updateNotificationIcon() {
        scope.launch {
            runCatching {
                val context = BettboxApplication.getAppContext()
                val notificationManager = context.getSystemService(android.app.NotificationManager::class.java)
                notificationManager?.cancel(GlobalState.NOTIFICATION_ID)
                (bettBoxService as? BettboxService)?.resetNotificationBuilder()
                (bettBoxService as? BettboxVpnService)?.resetNotificationBuilder()
                bettBoxService?.startForeground()
            }.onFailure {
                android.util.Log.e("VpnPlugin", "updateNotificationIcon error: ${it.message}")
            }
        }
    }

    fun handleUpdateNotificationSpeed(profileName: String, speedInfo: String) {
        if (profileName != GlobalState.currentProfileName ||
            !GlobalState.isSpeedNotificationEnabled
        ) {
            GlobalState.currentProfileName = profileName
            GlobalState.isSpeedNotificationEnabled = true
        }
        updateNotificationSpeed(profileName, speedInfo)
    }

    fun updateNotificationSpeed(profileName: String, speedInfo: String) {
        scope.launch {
            runCatching {
                (bettBoxService as? BettboxVpnService)?.updateNotificationSpeed(profileName, speedInfo)
            }.onFailure {
                android.util.Log.e("VpnPlugin", "updateNotificationSpeed error: ${it.message}")
            }
        }
    }

    fun setHighPriorityNotification(enabled: Boolean) {
        GlobalState.isNotificationHighPriority = enabled
        (bettBoxService as? BettboxService)?.resetNotificationBuilder()
        (bettBoxService as? BettboxVpnService)?.resetNotificationBuilder()
        if (GlobalState.currentRunState == RunState.START) {
            scope.launch {
                startForeground()
            }
        }
    }

    fun getStatus(): Boolean {
        return GlobalState.runLock.withLock {
            GlobalState.currentRunState == RunState.START && bettBoxService != null
        }
    }

    private fun handleStartService(intentEpoch: Long = nativeRecoveryPolicy.intentEpoch) {
        if (!nativeRecoveryPolicy.shouldStartAfterBind(intentEpoch, false,
                GlobalState.isSmartStopped, GlobalState.isCurrentlyStopping())) {
            android.util.Log.w("VpnPlugin", "VPN is in stopping state, ignore start request")
            return
        }
        if (bettBoxService == null) {
            bindService(intentEpoch = intentEpoch)
            return
        }
        
        scope.launch {
            coreStartMutex.withCoroutineLock {
            coreStartInFlight.set(true)
            try {
                if (!nativeRecoveryPolicy.shouldStartAfterBind(intentEpoch, false,
                        GlobalState.isSmartStopped, GlobalState.isCurrentlyStopping())) return@launch
                if (options?.enable == true) {
                    val prepareIntent = try {
                        android.net.VpnService.prepare(BettboxApplication.getAppContext())
                    } catch (e: Exception) {
                        null
                    }

                    if (prepareIntent != null) {
                        android.util.Log.w("VpnPlugin", "VPN permission required before start")
                        GlobalState.updateRunState(RunState.STOP)
                        withContext(Dispatchers.Main) {
                            GlobalState.getCurrentAppPlugin()?.requestVpnPermission {
                                handleStartService(intentEpoch)
                            }
                        }
                        return@launch
                    }
                }

                val currentOptions = options
                val nativeReady = currentOptions?.enable != true ||
                    (Core.androidTunReady() && !Core.nativeVpnRepairRequired())
                val startAllowed = GlobalState.runLock.withLock {
                    if (!nativeRecoveryPolicy.shouldStartAfterBind(intentEpoch, false,
                            GlobalState.isSmartStopped, GlobalState.isCurrentlyStopping())) return@withLock false
                    if (currentOptions?.enable == true &&
                        !nativeRecoveryPolicy.isIntentCurrent(intentEpoch)) return@withLock false
                    if (!NativeRecoveryPolicy.shouldStartCore(
                            GlobalState.currentRunState == RunState.START, nativeReady)) {
                        android.util.Log.d("VpnPlugin", "Service already running, refreshing notification")
                        scope.launch { startForeground() }
                        return@withLock false
                    }
                    if (currentOptions == null) {
                        android.util.Log.e("VpnPlugin", "Start failed: options is null")
                        GlobalState.updateRunState(RunState.STOP)
                        return@withLock false
                    }
                    GlobalState.updateRunState(RunState.START)
                    lastStartForegroundParams = null
                    true
                }

                if (!startAllowed || currentOptions == null) return@launch

                performStartCoreInternal(currentOptions, retry = true, notifyOnFailure = true, intentEpoch = intentEpoch)
            } catch (e: Exception) {
                android.util.Log.e("VpnPlugin", "Fatal error in start flow: ${e.message}")
                if (nativeRecoveryPolicy.isIntentCurrent(intentEpoch)) GlobalState.updateRunState(RunState.STOP)
            } finally {
                coreStartInFlight.set(false)
            }
            }
        }
    }

    private suspend fun performStartCore(
        currentOptions: VpnOptions,
        retry: Boolean,
        notifyOnFailure: Boolean,
        recoveryToken: Long? = null,
    ) {
        val intentEpoch = nativeRecoveryPolicy.intentEpoch
        coreStartMutex.withCoroutineLock {
            coreStartInFlight.set(true)
            try {
                if (recoveryToken != null) {
                    if (!nativeRecoveryPolicy.isCurrent(recoveryToken) ||
                        GlobalState.isSmartStopped || GlobalState.isCurrentlyStopping() ||
                        getActivePhysicalNetworks().isEmpty()) return@withCoroutineLock
                    // A queued normal start may already have repaired the core.
                    // Reconcile admission from resources before deciding to rebuild.
                    if (!Core.nativeVpnRepairRequired() || Core.restoreNativeVpnAdmission()) {
                        return@withCoroutineLock
                    }
                }
                performStartCoreInternal(currentOptions, retry, notifyOnFailure, intentEpoch, recoveryToken)
            } finally {
                coreStartInFlight.set(false)
            }
        }
    }

    private suspend fun performStartCoreInternal(
        currentOptions: VpnOptions,
        retry: Boolean,
        notifyOnFailure: Boolean,
        intentEpoch: Long,
        recoveryToken: Long? = null,
    ) {
        fun currentRequest(): Boolean =
            nativeRecoveryPolicy.shouldStartAfterBind(intentEpoch, false,
                GlobalState.isSmartStopped, GlobalState.isCurrentlyStopping()) &&
            (!currentOptions.enable ||
            (nativeRecoveryPolicy.isIntentCurrent(intentEpoch) &&
                (recoveryToken == null || nativeRecoveryPolicy.isCurrent(recoveryToken))))
        if (!currentRequest()) return
        val serviceRef = bettBoxService
        var fd: Int? = 0
        var nativeOwnsFd = false
        try {
        try {
            fd = serviceRef?.start(currentOptions)
        } catch (e: Exception) {
            android.util.Log.e("VpnPlugin", "First start attempt failed: ${e.message}")
        }

        if (fd == null || (currentOptions.enable && fd <= 0)) {
            if (retry) {
                android.util.Log.w("VpnPlugin", "VPN establish failed, retrying...")
                delay(300)
                try {
                    fd = serviceRef?.start(currentOptions)
                } catch (e: Exception) {
                    android.util.Log.e("VpnPlugin", "Retry start failed: ${e.message}")
                }
            }
        }

        if (!currentRequest()) {
            serviceRef?.stop()
            return
        }
        if (fd == null || (currentOptions.enable && fd <= 0)) {
            android.util.Log.e("VpnPlugin", "VPN start failed after all attempts")
            GlobalState.runLock.withLock { GlobalState.updateRunState(RunState.STOP) }
            if (notifyOnFailure) {
                ServicePlugin.notifyVpnStartFailed()
            }
            return
        }

        val canStart = GlobalState.runLock.withLock {
            if (GlobalState.currentRunState != RunState.START) {
                serviceRef?.stop()
                false
            } else true
        }
        if (!canStart) return

        nativeOwnsFd = true
        val coreStarted = com.appshub.bettbox.core.Core.startTun(
            fd = fd ?: 0,
            protect = this@VpnPlugin::protect,
            resolverProcess = this@VpnPlugin::resolverProcess,
        )

        if (!currentRequest()) {
            Core.stopTun()
            serviceRef?.stop()
            return
        }

        if (!coreStarted) {
            GlobalState.runLock.withLock { GlobalState.updateRunState(RunState.STOP) }
            serviceRef?.stop()
            if (notifyOnFailure) ServicePlugin.notifyVpnStartFailed()
            return
        }

        GlobalState.runLock.withLock {
            if (GlobalState.currentRunState != RunState.START) {
                Core.stopTun()
                return@withLock
            }
            scope.launch { startForeground() }
            if (currentOptions.dozeSuspend) {
                suspendModule?.uninstall()
                suspendModule = SuspendModule(BettboxApplication.getAppContext())
                suspendModule?.install()
            }
        }
        onUpdateNetwork()
        } finally {
            // establish().detachFd() transfers ownership to this coroutine.
            // Go owns it only after JNI entry; stopSelf() does not close it.
            if (!nativeOwnsFd && (fd ?: 0) > 0) {
                runCatching { ParcelFileDescriptor.adoptFd(fd!!).close() }
            }
        }
    }

    private fun protect(fd: Int): Boolean {
        var retries = 0
        while (retries < 5) {
            val success = runCatching {
                (bettBoxService as? BettboxVpnService)?.protect(fd) == true
            }.getOrDefault(false)

            if (success) return true

            retries++
            if (retries < 5) {
                Thread.sleep(60)
            }
        }
        android.util.Log.e("VpnPlugin", "protect failed for fd $fd after retries")
        return false
    }

    private fun resolverProcess(
        protocol: Int,
        source: InetSocketAddress,
        target: InetSocketAddress,
        uid: Int,
    ): String = runCatching {
        val nextUid = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            connectivity?.getConnectionOwnerUid(protocol, source, target) ?: -1
        } else {
            uid
        }
        if (nextUid == -1) {
            return@runCatching ""
        }
        uidPageNameMap.getOrPut(nextUid) {
            BettboxApplication.getAppContext().packageManager?.getPackagesForUid(nextUid)
                ?.firstOrNull() ?: ""
        }
    }.getOrElse {
        android.util.Log.e("VpnPlugin", "resolverProcess error: ${it.message}")
        ""
    }

    fun handleStop(force: Boolean = false) {
        nativeRecoveryPolicy.cancelIntent()
        nativeRecoveryJob?.cancel()
        nativeRecoveryJob = null
        bindTimeoutJob?.cancel()
        bindTimeoutJob = null
        val hadBinding = synchronized(bindingLock) {
            pendingBindRequest = null
            val active = isBind || isBinding.getAndSet(false)
            isBind = false
            active
        }
        if (hadBinding) {
            runCatching { BettboxApplication.getAppContext().unbindService(connection) }
                .onFailure { android.util.Log.w("VpnPlugin", "cancel pending bind: ${it.message}") }
        }
        android.util.Log.i(
            "VpnPlugin",
            "handleStop force=$force caller=${Throwable().stackTrace.getOrNull(1)?.methodName ?: "unknown"}",
        )
        var serviceRef: BaseServiceInterface? = null
        var shouldForceStop = false
        var alreadyStopped = false
        GlobalState.runLock.withLock {
            alreadyStopped = !force && GlobalState.currentRunState == RunState.STOP
            if (!alreadyStopped) {
                GlobalState.updateIsStopping(true)
                GlobalState.updateRunState(RunState.STOP)
                ServicePlugin.notifyRunStateChanged(RunState.STOP)
                serviceRef = bettBoxService
                shouldForceStop = force || bettBoxService == null
            }
        }

        if (alreadyStopped) {
            bettBoxService = null
            return
        }

        suspendModule?.uninstall()
        suspendModule = null
        Core.stopTun()
        serviceRef?.stop()

        runCatching {
            bettBoxService = null
        }.onFailure {
            android.util.Log.e("VpnPlugin", "unbindService error: ${it.message}")
        }

        val context = BettboxApplication.getAppContext()
        if (shouldForceStop) {
            context.stopService(Intent(context, BettboxVpnService::class.java))
            context.stopService(Intent(context, BettboxService::class.java))
        }

        runCatching {
            context.getSystemService<android.app.NotificationManager>()
                ?.cancel(GlobalState.NOTIFICATION_ID)
        }.onFailure {
            android.util.Log.e("VpnPlugin", "cancel notification error: ${it.message}")
        }

        scope.launch {
            delay(300)
            GlobalState.updateIsStopping(false)
            delay(200)
            withContext(Dispatchers.Main) {
                GlobalState.handleTryDestroy()
            }
        }
    }

    fun handleSmartStop() {
        GlobalState.runLock.withLock {
            if (GlobalState.currentRunState == RunState.STOP) return
            GlobalState.updateRunState(RunState.STOP)
            GlobalState.isSmartStopped = true
        }
        suspendModule?.uninstall()
        suspendModule = null
        Core.stopTun()
        Core.suspended(true)
        (bettBoxService as? BettboxService)?.resetNotificationBuilder()
        (bettBoxService as? BettboxVpnService)?.resetNotificationBuilder()
        scope.launch {
            startForeground()
        }
        scope.launch(Dispatchers.Main) {
            Toast.makeText(BettboxApplication.getAppContext(), "Bettbox Suspended", Toast.LENGTH_SHORT).show()
        }
        ServicePlugin.notifyNetworkChanged()
    }

    fun handleSmartResume(options: VpnOptions): Boolean {
        nativeRecoveryPolicy.setWanted(options.enable)
        if (options.enable) startNativeRecoveryWatchdog()
        scope.launch {
            val startAllowed = GlobalState.runLock.withLock {
                if (GlobalState.currentRunState == RunState.START) return@withLock false
                GlobalState.isSmartStopped = false
                this@VpnPlugin.options = options

                if (bettBoxService == null) {
                    bindService()
                    return@withLock false
                }

                GlobalState.updateRunState(RunState.START)
                lastStartForegroundParams = null
                true
            }
            if (!startAllowed) return@launch

            Core.suspended(false)
            (bettBoxService as? BettboxService)?.resetNotificationBuilder()
            (bettBoxService as? BettboxVpnService)?.resetNotificationBuilder()
            performStartCore(options, retry = false, notifyOnFailure = false)
            withContext(Dispatchers.Main) {
                Toast.makeText(BettboxApplication.getAppContext(), "Bettbox Connected", Toast.LENGTH_SHORT).show()
            }
            ServicePlugin.notifyNetworkChanged()
        }
        return true
    }

    private fun bindService(
        automatic: Boolean = false,
        intentEpoch: Long = nativeRecoveryPolicy.intentEpoch,
    ) {
        val beginBinding = synchronized(bindingLock) {
            if (!nativeRecoveryPolicy.isEpochCurrent(intentEpoch)) return@synchronized false
            pendingBindRequest = NativeRecoveryPolicy.mergeBind(pendingBindRequest,
                NativeRecoveryPolicy.BindRequest(intentEpoch, automatic))
            isBinding.compareAndSet(false, true)
        }
        if (!beginBinding) return

        bindTimeoutJob?.cancel()
        bindTimeoutJob = scope.launch {
            delay(10_000L)
            val timedOut = synchronized(bindingLock) {
                if (!isBinding.get()) false
                else {
                    isBinding.set(false)
                    pendingBindRequest = null
                    true
                }
            }
            if (timedOut) {
                android.util.Log.w("VpnPlugin", "bindService timeout (10s), resetting bind state")
                runCatching { BettboxApplication.getAppContext().unbindService(connection) }
                    .onFailure { android.util.Log.w("VpnPlugin", "unbind timed out service: ${it.message}") }
                GlobalState.runLock.withLock {
                    if (GlobalState.currentRunState == RunState.PENDING) {
                        GlobalState.updateRunState(RunState.STOP)
                    }
                }
            }
        }

        try {
            if (isBind) {
                BettboxApplication.getAppContext().unbindService(connection)
                isBind = false
            }
            val intent = Intent(
                BettboxApplication.getAppContext(),
                if (options?.enable == true) BettboxVpnService::class.java else BettboxService::class.java
            )
            val res = BettboxApplication.getAppContext().bindService(intent, connection, Context.BIND_AUTO_CREATE)
            if (!res) {
                synchronized(bindingLock) {
                    isBinding.set(false)
                    pendingBindRequest = null
                }
                bindTimeoutJob?.cancel()
                bindTimeoutJob = null
                android.util.Log.e("VpnPlugin", "bindService returned false (rejected by system)")
            } else {
                val keepBinding = synchronized(bindingLock) {
                    isBind || (isBinding.get() && pendingBindRequest?.let {
                        nativeRecoveryPolicy.isEpochCurrent(it.intentEpoch)
                    } == true)
                }
                if (!keepBinding) runCatching {
                    BettboxApplication.getAppContext().unbindService(connection)
                }
            }
        } catch (e: Exception) {
            synchronized(bindingLock) {
                isBinding.set(false)
                pendingBindRequest = null
            }
            bindTimeoutJob?.cancel()
            bindTimeoutJob = null
            android.util.Log.e("VpnPlugin", "bindService error: ${e.message}")
        }
    }
}
