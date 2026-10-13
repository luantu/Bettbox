package com.appshub.bettbox.plugins;

/** Coalesces real native transport failures without undoing user stop intent. */
public final class NativeRecoveryPolicy {
    public static final class BindRequest {
        public final long intentEpoch;
        public final boolean automatic;
        public BindRequest(long intentEpoch, boolean automatic) {
            this.intentEpoch = intentEpoch;
            this.automatic = automatic;
        }
    }

    public static BindRequest mergeBind(BindRequest pending, BindRequest incoming) {
        if (pending == null || incoming.intentEpoch > pending.intentEpoch) return incoming;
        if (incoming.intentEpoch < pending.intentEpoch) return pending;
        return incoming.automatic ? pending : incoming;
    }

    public static boolean shouldStartCore(boolean running, boolean nativeReady) {
        return !running || !nativeReady;
    }
    private boolean wanted;
    private long intentEpoch;
    private long serial;
    private Long inFlight;
    private int failures;
    private long retryAt;

    public synchronized void setWanted(boolean value) {
        if (wanted == value) return;
        wanted = value;
        intentEpoch++;
        serial++;
        inFlight = null;
        failures = 0;
        retryAt = 0;
    }

    public synchronized void cancelIntent() {
        wanted = false;
        intentEpoch++;
        serial++;
        inFlight = null;
        failures = 0;
        retryAt = 0;
    }

    public synchronized boolean isWanted() {
        return wanted;
    }

    public synchronized long getIntentEpoch() {
        return intentEpoch;
    }

    public synchronized boolean isIntentCurrent(long epoch) {
        return wanted && intentEpoch == epoch;
    }

    public synchronized boolean isEpochCurrent(long epoch) {
        return intentEpoch == epoch;
    }

    public synchronized boolean shouldStartAfterBind(long epoch, boolean automatic,
                                                      boolean paused, boolean stopping) {
        return intentEpoch == epoch && !automatic && !paused && !stopping;
    }

    public synchronized Long tryBegin(long now, boolean blocked, boolean paused,
                                       boolean stopping, boolean physicalAvailable) {
        if (!wanted || !blocked || paused || stopping || !physicalAvailable
                || inFlight != null || now < retryAt) return null;
        inFlight = ++serial;
        return inFlight;
    }

    public synchronized boolean isCurrent(Long token) {
        return wanted && token != null && token.equals(inFlight);
    }

    public synchronized void finish(Long token, long now, boolean ready) {
        if (!isCurrent(token)) return;
        inFlight = null;
        if (ready) {
            failures = 0;
            retryAt = 0;
        } else {
            failures = Math.min(failures + 1, 5);
            long delay = Math.min(2000L << (failures - 1), 30000L);
            retryAt = now + delay;
        }
    }
}
