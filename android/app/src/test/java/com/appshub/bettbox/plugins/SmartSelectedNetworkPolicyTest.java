package com.appshub.bettbox.plugins;

import java.util.Map;
import java.util.Objects;
import java.util.Set;

public final class SmartSelectedNetworkPolicyTest {
    private static final int CELL = 0;
    private static final int WIFI = 1;
    private static void equal(Object expected, Object actual, String message) {
        if (!Objects.equals(expected, actual)) throw new AssertionError(message + ": " + actual);
    }

    public static void main(String[] args) {
        // System VPN inherits its actual cellular transport. An unvalidated Wi-Fi
        // must not win merely by type; a Wi-Fi-only rule sees no selected Wi-Fi.
        Map<String, Set<Integer>> networks = Map.of("cell", Set.of(CELL), "wifi", Set.of(WIFI));
        equal("cell", SmartSelectedNetworkPolicy.select("vpn", true, Set.of(CELL), networks),
                "active VPN with cellular egress must not select idle Wi-Fi");
        equal("wifi", SmartSelectedNetworkPolicy.select("vpn", true, Set.of(WIFI), networks),
                "actual Wi-Fi egress can select Wi-Fi");
        equal(null, SmartSelectedNetworkPolicy.select("vpn", true, Set.of(CELL, WIFI), networks),
                "multiple inherited transports are ambiguous, regardless of validation/ranking");
        equal(null, SmartSelectedNetworkPolicy.select("vpn", true, Set.of(), Map.of("wifi", Set.of(WIFI))),
                "missing system evidence cannot guess even from a sole available network");
        equal(null, SmartSelectedNetworkPolicy.select("vpn", true, Set.of(WIFI),
                Map.of("wifi1", Set.of(WIFI), "wifi2", Set.of(WIFI))), "two Wi-Fi candidates are ambiguous");
        equal(null, SmartSelectedNetworkPolicy.select("vpn", true, Set.of(WIFI),
                Map.of("cell", Set.of(CELL))), "inherited transport must have a live candidate");
        equal("cell", SmartSelectedNetworkPolicy.select("cell", false, Set.of(CELL), networks),
                "non-VPN activeNetwork is authoritative");
        equal("wifi", SmartSelectedNetworkPolicy.select("wifi", false, Set.of(WIFI), Map.of()),
                "non-VPN activeNetwork does not depend on callback enumeration");
        equal(null, SmartSelectedNetworkPolicy.select(null, false, Set.of(), networks), "no active network");
        equal(null, SmartSelectedNetworkPolicy.select("vpn", true, Set.of(WIFI),
                Map.of("bridge", Set.of(CELL, WIFI))), "multi-transport physical candidate is not proof");
        System.out.println("SmartSelectedNetworkPolicy: all behavior checks passed");
    }
}
