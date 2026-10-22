package com.appshub.bettbox.services;

/** Pure behavior checks for choosing a desktop shortcut delivery path. */
public final class CompatibilityShortcutPolicyTest {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        check(CompatibilityShortcutPolicy.afterRefresh(
                        true, true, true, true) ==
                    CompatibilityShortcutPolicy.Action.COMPLETE,
                "a refreshed pinned shortcut is already complete");
        check(CompatibilityShortcutPolicy.afterRefresh(
                        true, false, true, true) ==
                    CompatibilityShortcutPolicy.Action.REQUEST_MODERN,
                "a failed refresh must retry through the modern API");
        check(CompatibilityShortcutPolicy.afterRefresh(
                        false, false, true, true) ==
                    CompatibilityShortcutPolicy.Action.REQUEST_MODERN,
                "new shortcuts must prefer the modern API");
        check(CompatibilityShortcutPolicy.afterRefresh(
                        false, false, false, true) ==
                    CompatibilityShortcutPolicy.Action.TRY_LEGACY,
                "legacy is used only when modern pinning is unavailable");
        check(CompatibilityShortcutPolicy.afterRefresh(
                        false, false, false, false) ==
                    CompatibilityShortcutPolicy.Action.FAIL,
                "unsupported launchers must report failure");

        check(CompatibilityShortcutPolicy.afterModern(true, true) ==
                    CompatibilityShortcutPolicy.Action.COMPLETE,
                "an accepted modern request completes the request path");
        check(CompatibilityShortcutPolicy.afterModern(false, true) ==
                    CompatibilityShortcutPolicy.Action.TRY_LEGACY,
                "legacy fallback runs only after modern rejection");
        check(CompatibilityShortcutPolicy.afterModern(false, false) ==
                    CompatibilityShortcutPolicy.Action.FAIL,
                "modern rejection without a fallback must report failure");

        System.out.println("CompatibilityShortcutPolicy: all behavior checks passed");
    }
}
