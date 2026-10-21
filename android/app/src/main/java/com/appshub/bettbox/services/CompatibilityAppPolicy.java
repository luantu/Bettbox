package com.appshub.bettbox.services;

/** Pure decisions for temporarily suspending VPN around an incompatible app. */
public final class CompatibilityAppPolicy {
    private CompatibilityAppPolicy() {}

    public static boolean shouldPause(boolean vpnRunning, boolean userWantsVpn) {
        return vpnRunning && userWantsVpn;
    }

    public static boolean shouldResume(
            boolean pausedByCompatibility,
            boolean userWantsVpn,
            boolean targetSeen,
            String foregroundPackage,
            String targetPackage,
            boolean transientSystemUi,
            long awayDurationMillis,
            long graceMillis) {
        if (!pausedByCompatibility || !userWantsVpn || !targetSeen) return false;
        if (foregroundPackage == null || foregroundPackage.isBlank()) return false;
        if (foregroundPackage.equals(targetPackage) || transientSystemUi) return false;
        return awayDurationMillis >= graceMillis;
    }
}
