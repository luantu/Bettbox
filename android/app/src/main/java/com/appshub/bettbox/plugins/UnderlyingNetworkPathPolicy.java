package com.appshub.bettbox.plugins;

import java.util.Objects;

/** Detects physical path changes even when Android reuses one Network handle. */
public final class UnderlyingNetworkPathPolicy {
    private boolean initialized;
    private long networkHandle;
    private String fingerprint = "";

    public synchronized boolean update(long handle, String nextFingerprint, boolean running) {
        String normalized = nextFingerprint == null ? "" : nextFingerprint;
        boolean changed = initialized
                && (networkHandle != handle || !Objects.equals(fingerprint, normalized));
        initialized = true;
        networkHandle = handle;
        fingerprint = normalized;
        return running && changed;
    }

    public synchronized void reset() {
        initialized = false;
        networkHandle = 0;
        fingerprint = "";
    }
}
