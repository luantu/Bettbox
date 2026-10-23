package com.appshub.bettbox.plugins;

import java.util.ArrayList;
import java.util.List;
import java.util.function.Consumer;

/** Owns outstanding Flutter replies; Android permission UI remains in AppPlugin. */
public final class SmartWifiPermissionRequest {
    public static boolean isPreciseGrant(String[] permissions, int[] results, boolean readBackGranted) {
        if (!readBackGranted) return false;
        for (int index = 0; index < permissions.length; index++) {
            if ("android.permission.ACCESS_FINE_LOCATION".equals(permissions[index])) {
                return index < results.length && results[index] == 0; // PackageManager.PERMISSION_GRANTED
            }
        }
        return false;
    }

    private final List<Consumer<Boolean>> replies = new ArrayList<>();

    public synchronized boolean begin(Consumer<Boolean> reply) {
        boolean launch = replies.isEmpty();
        replies.add(reply);
        return launch;
    }

    public void complete(boolean granted) {
        List<Consumer<Boolean>> pending;
        synchronized (this) {
            pending = new ArrayList<>(replies);
            replies.clear();
        }
        for (Consumer<Boolean> reply : pending) reply.accept(granted);
    }
}
