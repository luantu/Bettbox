package com.appshub.bettbox.plugins;

import java.util.List;
import java.util.Map;
import java.util.Objects;

public final class SmartNetworkPolicyTest {
    private static void equal(Object expected, Object actual, String message) {
        if (!Objects.equals(expected, actual)) {
            throw new AssertionError(message + ": expected=" + expected + ", actual=" + actual);
        }
    }

    public static void main(String[] args) {
        // Removing unquoting, trimming SSIDs, or treating redaction as a name is a bug.
        equal(" 家里 WiFi ", SmartNetworkPolicy.normalizeSsid("\" 家里 WiFi \""), "preserve spaces and Unicode");
        equal("CaseSensitive", SmartNetworkPolicy.normalizeSsid("CaseSensitive"), "preserve case");
        equal("ab12", SmartNetworkPolicy.normalizeSsid("ab12"), "preserve Android hex SSIDs");
        equal(null, SmartNetworkPolicy.normalizeSsid("<unknown ssid>"), "redacted SSID");
        equal(null, SmartNetworkPolicy.normalizeSsid("\"<unknown ssid>\""), "quoted redaction");
        equal(null, SmartNetworkPolicy.normalizeSsid("\"\""), "empty SSID");
        equal(null, SmartNetworkPolicy.normalizeSsid(null), "missing SSID");

        // A global connection SSID must never be assigned to another Wi-Fi or a duplicate IP.
        equal("205", SmartNetworkPolicy.fallbackOwner(Map.of(
                "205", List.of("192.168.1.2"), "206", List.of("192.168.2.2")), "192.168.1.2"), "owning network");
        equal(null, SmartNetworkPolicy.fallbackOwner(Map.of(
                "205", List.of("192.168.1.2"), "206", List.of("192.168.1.2")), "192.168.1.2"), "ambiguous address");
        equal(null, SmartNetworkPolicy.fallbackOwner(Map.of("205", List.of("192.168.1.2")), "192.168.9.2"), "foreign address");
        equal(null, SmartNetworkPolicy.fallbackOwner(Map.of("205", List.of("0.0.0.0")), "0.0.0.0"), "unset address");

        equal("Secondary", SmartNetworkPolicy.ssidForNetwork(true, true, "\"Secondary\"", "\"Primary\"", true), "own WifiInfo wins");
        equal("Primary", SmartNetworkPolicy.ssidForNetwork(true, true, "<unknown ssid>", "\"Primary\"", true), "redacted own info may use owned fallback");
        equal(null, SmartNetworkPolicy.ssidForNetwork(true, true, null, "\"Primary\"", false), "do not borrow a different Wi-Fi SSID");
        equal(null, SmartNetworkPolicy.ssidForNetwork(false, true, null, "\"Primary\"", true), "never label cellular as Wi-Fi");
        equal(null, SmartNetworkPolicy.ssidForNetwork(true, false, "\"Cached\"", "\"Primary\"", true), "do not expose stale names after revocation");

        equal("notWifi", SmartNetworkPolicy.ssidStatus(false, false, false, null), "cellular is not a permission failure");
        equal("permissionRequired", SmartNetworkPolicy.ssidStatus(true, false, true, "cached"), "revocation beats stale data");
        equal("locationDisabled", SmartNetworkPolicy.ssidStatus(true, true, false, "cached"), "location switch beats cached data");
        equal("unavailable", SmartNetworkPolicy.ssidStatus(true, true, true, null), "unknown is explicit");
        equal("available", SmartNetworkPolicy.ssidStatus(true, true, true, "Home"), "readable SSID");
        System.out.println("SmartNetworkPolicy: all behavior checks passed");
    }
}
