package com.appshub.bettbox.services;

/** Pure behavior checks for the no-root compatibility-app pause window. */
public final class CompatibilityAppPolicyTest {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        String target = "com.yadea.smartmoto";

        check(!CompatibilityAppPolicy.shouldPause(false, true),
                "a stopped VPN must not create an auto-resume obligation");
        check(!CompatibilityAppPolicy.shouldPause(true, false),
                "an explicit user stop must not be overridden");
        check(CompatibilityAppPolicy.shouldPause(true, true),
                "a running wanted VPN may open a compatibility pause window");

        check(!CompatibilityAppPolicy.shouldResume(
                        true, true, false, "launcher", target, false, 20_000, 10_000),
                "the target must be observed in foreground before auto-resume");
        check(!CompatibilityAppPolicy.shouldResume(
                        true, true, true, target, target, false, 20_000, 10_000),
                "never resume while the target app is foreground");
        check(!CompatibilityAppPolicy.shouldResume(
                        true, false, true, "launcher", target, false, 20_000, 10_000),
                "manual stop while the app is open must cancel auto-resume");
        check(!CompatibilityAppPolicy.shouldResume(
                        true, true, true, "com.android.settings", target, true, 20_000, 10_000),
                "temporary system UI must not trigger a premature resume");
        check(!CompatibilityAppPolicy.shouldResume(
                        true, true, true, "launcher", target, false, 9_999, 10_000),
                "leaving for less than the grace period must not resume");
        check(CompatibilityAppPolicy.shouldResume(
                        true, true, true, "launcher", target, false, 10_000, 10_000),
                "a stable departure after the grace period may resume");

        System.out.println("CompatibilityAppPolicy: all behavior checks passed");
    }
}
