package com.appshub.bettbox.plugins;

import java.util.Map;
import java.util.Set;

/** Uses system default evidence only; never ranks Wi-Fi, validation, or handles. */
public final class SmartSelectedNetworkPolicy {
    private SmartSelectedNetworkPolicy() {}

    public static <T> T select(T active, boolean vpn, Set<Integer> inheritedTransports,
                               Map<T, Set<Integer>> physicalTransports) {
        if (active == null) return null;
        if (!vpn) return active;
        // On API 26+ VPN capabilities inherit underlying transports. Multiple
        // transports cannot identify a single physical exit, even if one is validated.
        if (inheritedTransports.size() != 1) return null;
        T selected = null;
        for (Map.Entry<T, Set<Integer>> item : physicalTransports.entrySet()) {
            if (!item.getValue().equals(inheritedTransports)) continue;
            if (selected != null) return null;
            selected = item.getKey();
        }
        return selected;
    }
}
