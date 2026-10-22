package com.appshub.bettbox.services;

/** Pure decision table for delivering or refreshing a compatibility shortcut. */
public final class CompatibilityShortcutPolicy {
    public enum Action {
        COMPLETE,
        REQUEST_MODERN,
        TRY_LEGACY,
        FAIL,
    }

    private CompatibilityShortcutPolicy() {}

    public static Action afterRefresh(
            boolean alreadyPinned,
            boolean refreshSucceeded,
            boolean modernSupported,
            boolean legacySupported) {
        if (alreadyPinned && refreshSucceeded) return Action.COMPLETE;
        if (modernSupported) return Action.REQUEST_MODERN;
        if (legacySupported) return Action.TRY_LEGACY;
        return Action.FAIL;
    }

    public static Action afterModern(boolean accepted, boolean legacySupported) {
        if (accepted) return Action.COMPLETE;
        if (legacySupported) return Action.TRY_LEGACY;
        return Action.FAIL;
    }
}
