package com.appshub.bettbox.plugins;

import java.util.List;
import java.util.Map;

/** Android-independent SSID normalization and connection ownership checks. */
public final class SmartNetworkPolicy {
    private SmartNetworkPolicy() {}

    public static String normalizeSsid(String raw) {
        if (raw == null) return null;
        String value = raw;
        if (value.length() >= 2 && value.startsWith("\"") && value.endsWith("\"")) {
            value = value.substring(1, value.length() - 1);
        }
        return value.isEmpty() || "<unknown ssid>".equals(value) ? null : value;
    }

    public static String fallbackOwner(Map<String, List<String>> wifiAddresses, String address) {
        if (address == null || address.isEmpty() || "0.0.0.0".equals(address)) return null;
        String owner = null;
        for (Map.Entry<String, List<String>> entry : wifiAddresses.entrySet()) {
            if (!entry.getValue().contains(address)) continue;
            if (owner != null) return null;
            owner = entry.getKey();
        }
        return owner;
    }

    public static String ssidForNetwork(boolean wifi, boolean readable, String own,
                                       String fallback, boolean ownsFallback) {
        if (!wifi || !readable) return null;
        String direct = normalizeSsid(own);
        return direct != null ? direct : ownsFallback ? normalizeSsid(fallback) : null;
    }

    public static String ssidStatus(boolean wifi, boolean permission, boolean location, String ssid) {
        if (!wifi) return "notWifi";
        if (!permission) return "permissionRequired";
        if (!location) return "locationDisabled";
        return ssid == null ? "unavailable" : "available";
    }
}
