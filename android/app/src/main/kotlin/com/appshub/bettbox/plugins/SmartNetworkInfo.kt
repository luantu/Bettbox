package com.appshub.bettbox.plugins

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import java.util.concurrent.ConcurrentHashMap

/** A read-only snapshot of connected physical networks. Never scans for nearby Wi-Fi. */
object SmartNetworkInfo {
    // Only per-Network callback data; never copy one network's WifiInfo to another.
    private val observedCapabilities = ConcurrentHashMap<Network, NetworkCapabilities>()

    fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
        observedCapabilities[network] = capabilities
    }

    fun onLost(network: Network) {
        observedCapabilities.remove(network)
    }

    fun clear() = observedCapabilities.clear()

    private data class PhysicalNetwork(
        val network: Network,
        val capabilities: NetworkCapabilities,
        val link: LinkProperties?,
    ) {
        val id get() = network.networkHandle.toString()
        val wifi get() = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        val ips get() = link?.linkAddresses.orEmpty().map { it.address }
            .filter { !it.isLoopbackAddress && !it.isAnyLocalAddress }
            .mapNotNull { it.hostAddress }.distinct()
    }

    fun hasFineLocation(context: Context): Boolean = granted(context, Manifest.permission.ACCESS_FINE_LOCATION)

    fun backgroundLocationGranted(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            granted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        } else hasFineLocation(context)

    private fun granted(context: Context, permission: String): Boolean = runCatching {
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }.getOrDefault(false)

    private fun locationEnabled(context: Context): Boolean = runCatching {
        val manager = context.getSystemService(LocationManager::class.java) ?: return@runCatching false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) manager.isLocationEnabled
        else manager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
            manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    }.getOrDefault(false)

    private fun canReadLocation(context: Context): Boolean {
        if (!hasFineLocation(context)) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || backgroundLocationGranted(context)) return true
        // The VPN's specialUse foreground service is not a location foreground service.
        return runCatching {
            val state = ActivityManager.RunningAppProcessInfo()
            ActivityManager.getMyMemoryState(state)
            state.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
        }.getOrDefault(false)
    }

    @Suppress("DEPRECATION") // allNetworks remains available on API 26+; no Wi-Fi scan APIs.
    fun snapshot(context: Context, selected: Network?): Map<String, Any> {
        val backgroundGranted = backgroundLocationGranted(context)
        val cm = context.getSystemService(ConnectivityManager::class.java)
            ?: return mapOf("networks" to emptyList<Any>(), "backgroundLocationGranted" to backgroundGranted)
        val permission = canReadLocation(context) && granted(context, Manifest.permission.ACCESS_WIFI_STATE)
        val location = locationEnabled(context)
        val fallback = if (permission && location) readConnection(context) else null
        val all = runCatching { cm.allNetworks.toList() }.getOrDefault(emptyList())
        val physical = all.mapNotNull { network ->
            runCatching {
                val caps = cm.getNetworkCapabilities(network) ?: return@runCatching null
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return@runCatching null
                PhysicalNetwork(network, caps, cm.getLinkProperties(network))
            }.getOrNull()
        }
        val fallbackOwner = fallback?.let { info ->
            SmartNetworkPolicy.fallbackOwner(
                physical.filter { it.wifi }.associate { it.id to it.ips }, ipv4(info),
            )
        }
        // Bracket enumeration with connection reads. A handoff must not attach the new
        // primary SSID to LinkProperties from the old connection.
        val fallbackStable = fallback != null && sameConnection(fallback, readConnection(context)) &&
            runCatching { cm.allNetworks.toSet() == all.toSet() }.getOrDefault(false)
        val records = physical.sortedBy { it.network.networkHandle }.map { item ->
            val queriedInfo = wifiInfo(item.capabilities)
            val observedInfo = observedCapabilities[item.network]?.let(::wifiInfo)
                ?.takeIf { compatibleConnection(queriedInfo, it) }
            val ownInfo = queriedInfo?.takeIf { SmartNetworkPolicy.normalizeSsid(it.ssid) != null }
                ?: observedInfo ?: queriedInfo
            val ownsFallback = permission && location && item.wifi && fallbackStable &&
                item.id == fallbackOwner && compatibleConnection(ownInfo, fallback) &&
                runCatching {
                    cm.getLinkProperties(item.network)?.linkAddresses.orEmpty()
                        .any { it.address.hostAddress == fallback?.let(::ipv4) }
                }.getOrDefault(false)
            val ssid = SmartNetworkPolicy.ssidForNetwork(
                item.wifi, permission && location, ownInfo?.ssid, fallback?.ssid, ownsFallback,
            )
            val status = SmartNetworkPolicy.ssidStatus(item.wifi, permission, location, ssid)
            mapOf(
                "id" to item.id,
                "selected" to (item.network == selected),
                "transport" to when {
                    item.wifi -> "wifi"
                    item.capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                    item.capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                    else -> "other"
                },
                "ssid" to ssid.takeIf { status == "available" },
                "ssidStatus" to status,
                "ips" to item.ips,
                "gateways" to item.link?.routes.orEmpty().filter { it.isDefaultRoute }
                    .mapNotNull { it.gateway }.filter { !it.isAnyLocalAddress && !it.isLoopbackAddress }
                    .mapNotNull { it.hostAddress }.distinct(),
            )
        }
        return mapOf("networks" to records, "backgroundLocationGranted" to backgroundGranted)
    }

    private fun wifiInfo(capabilities: NetworkCapabilities): WifiInfo? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) capabilities.transportInfo as? WifiInfo else null

    @Suppress("DEPRECATION")
    private fun readConnection(context: Context): WifiInfo? = runCatching {
        context.applicationContext.getSystemService(WifiManager::class.java)?.connectionInfo
    }.getOrNull()

    @Suppress("DEPRECATION")
    private fun ipv4(info: WifiInfo): String? = info.ipAddress.takeIf { it != 0 }?.let { address ->
        (0..3).joinToString(".") { shift -> ((address ushr (shift * 8)) and 0xff).toString() }
    }

    private fun sameConnection(first: WifiInfo, second: WifiInfo?): Boolean = second != null &&
        first.networkId == second.networkId && first.bssid == second.bssid &&
        first.ssid == second.ssid && ipv4(first) == ipv4(second)

    private fun compatibleConnection(own: WifiInfo?, fallback: WifiInfo?): Boolean {
        if (own == null || fallback == null) return true
        if (own.networkId >= 0 && own.networkId != fallback.networkId) return false
        val bssid = own.bssid
        return bssid == null || bssid == "02:00:00:00:00:00" || bssid == fallback.bssid
    }
}
