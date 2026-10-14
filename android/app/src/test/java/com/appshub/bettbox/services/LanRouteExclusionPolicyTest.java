package com.appshub.bettbox.services;

import java.util.List;

/** Pure JVM behavior tests for Android TUN route exclusions. */
public final class LanRouteExclusionPolicyTest {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        check(LanRouteExclusionPolicy.effective(List.of()).isEmpty(),
                "an empty setting must preserve existing routing");

        List<String> routes = LanRouteExclusionPolicy.effective(List.of(
                "192.168.110.0/24", "192.168.111.0/24", "192.168.110.0/24", " "));
        check(routes.equals(List.of(
                        "192.168.110.0/24",
                        "192.168.111.0/24",
                        "169.254.0.0/16",
                        "224.0.0.0/4",
                        "fe80::/10",
                        "ff00::/8")),
                "configured LANs must bypass TUN together with discovery and link-local traffic");

        List<String> invalidIgnored = LanRouteExclusionPolicy.effective(List.of(
                "not-a-cidr", "192.168.1.0/33", "fe80::/129", "10.0.0.0/8"));
        check(invalidIgnored.get(0).equals("10.0.0.0/8"),
                "invalid CIDRs must not prevent a valid exclusion from applying");

        check(LanRouteExclusionPolicy.forAndroid(
                List.of("192.168.110.0/24"), 32, true).isEmpty(),
                "Android 12 must not call the Android 13 excludeRoute API");
        check(LanRouteExclusionPolicy.forAndroid(
                List.of("192.168.110.0/24"), 33, false).equals(List.of(
                "192.168.110.0/24", "169.254.0.0/16", "224.0.0.0/4")),
                "IPv6 exclusions must be omitted when the Android VPN has no IPv6 address");
        check(LanRouteExclusionPolicy.forAndroid(
                List.of("192.168.110.0/24"), 33, true).size() == 5,
                "Android 13 with IPv6 enabled must apply every effective exclusion");

        System.out.println("LanRouteExclusionPolicy: all behavior checks passed");
    }
}
