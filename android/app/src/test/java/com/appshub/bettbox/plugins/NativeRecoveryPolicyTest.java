package com.appshub.bettbox.plugins;

/** Standalone behavioral tests: no Android runtime, credentials or network. */
public final class NativeRecoveryPolicyTest {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        NativeRecoveryPolicy.BindRequest oldBind = new NativeRecoveryPolicy.BindRequest(1, true);
        NativeRecoveryPolicy.BindRequest newStart = new NativeRecoveryPolicy.BindRequest(3, false);
        check(NativeRecoveryPolicy.mergeBind(oldBind, newStart) == newStart,
                "a binding already in flight must retain the newer user start");
        check(NativeRecoveryPolicy.mergeBind(newStart, oldBind) == newStart,
                "an older automatic bind must not replace a newer start");
        check(NativeRecoveryPolicy.mergeBind(newStart,
                new NativeRecoveryPolicy.BindRequest(3, true)) == newStart,
                "automatic rebind must not downgrade an explicit start in the same epoch");
        check(NativeRecoveryPolicy.shouldStartCore(true, false),
                "running flag alone must not skip repair of an unavailable native channel");
        check(!NativeRecoveryPolicy.shouldStartCore(true, true),
                "a truly ready running channel must not be restarted");
        check(NativeRecoveryPolicy.shouldStartCore(false, true),
                "stopped service still needs the normal start path");
        NativeRecoveryPolicy policy = new NativeRecoveryPolicy();
        long proxyEpoch = policy.getIntentEpoch();
        policy.cancelIntent();
        check(policy.getIntentEpoch() != proxyEpoch,
                "stop must invalidate a pending proxy-only bind even when VPN wanted is already false");
        check(policy.tryBegin(0, true, false, false, true) == null,
                "an error must not start VPN without user running intent");
        policy.setWanted(true);
        long userEpoch = policy.getIntentEpoch();
        check(policy.isIntentCurrent(userEpoch), "start owns the current user intent");
        check(!policy.shouldStartAfterBind(userEpoch, true, false, false),
                "automatic bind must return to the watchdog, never the user start flow");
        check(policy.shouldStartAfterBind(userEpoch, false, false, false),
                "current explicit start can continue after binding");
        check(!policy.shouldStartAfterBind(userEpoch, false, true, false),
                "late service binding must not undo smart pause");
        check(!policy.shouldStartAfterBind(userEpoch, false, false, true),
                "late binding must not cross an active stop");
        check(policy.tryBegin(0, false, false, false, true) == null,
                "a healthy transport must not be restarted");
        check(policy.tryBegin(0, true, true, false, true) == null,
                "smart pause must remain paused");
        check(policy.tryBegin(0, true, false, true, true) == null,
                "stopping VPN must not be restarted");
        check(policy.tryBegin(0, true, false, false, false) == null,
                "offline handoff must wait for a physical network");
        Long first = policy.tryBegin(0, true, false, false, true);
        check(policy.isIntentCurrent(userEpoch), "a repair attempt must not change user intent");
        check(first != null, "real native denial must trigger recovery while wanted");
        check(policy.tryBegin(1, true, false, false, true) == null,
                "repeated handshake errors must share one recovery");
        policy.finish(first, 100, false);
        check(policy.tryBegin(2099, true, false, false, true) == null,
                "failed recovery must back off rather than spin");
        Long retry = policy.tryBegin(2100, true, false, false, true);
        check(retry != null, "failed recovery must eventually retry without user action");
        policy.finish(retry, 2200, true);
        check(policy.tryBegin(2201, false, false, false, true) == null,
                "successful recovery must not churn a healthy native channel");

        Long old = policy.tryBegin(2300, true, false, false, true);
        check(old != null, "a later real fault can recover");
        policy.setWanted(false);
        check(!policy.shouldStartAfterBind(userEpoch, false, false, false),
                "late explicit bind must not undo a newer user stop");
        check(!policy.isIntentCurrent(userEpoch), "stop invalidates a late native constructor");
        check(!policy.isCurrent(old), "manual stop invalidates pending recovery");
        check(policy.tryBegin(5000, true, false, false, true) == null,
                "residual WG handshake errors must not undo manual stop");
        policy.setWanted(true);
        check(!policy.isIntentCurrent(userEpoch),
                "stop then start must not permit an old constructor to publish");
        Long current = policy.tryBegin(5000, true, false, false, true);
        check(current != null && !current.equals(old), "new user start has a new epoch");
        policy.finish(old, 5100, false);
        check(policy.tryBegin(5200, true, false, false, true) == null,
                "old completion must not release the new in-flight recovery");
        policy.finish(current, 5300, true);
        Long later = policy.tryBegin(5301, true, false, false, true);
        check(later != null, "a stale failure must not poison the latest successful epoch");
        policy.finish(later, 5302, true);

        long now = 10000;
        long[] delays = {2000, 4000, 8000, 16000, 30000, 30000, 30000};
        for (long delay : delays) {
            Long attempt = policy.tryBegin(now, true, false, false, true);
            check(attempt != null, "each bounded cooldown must permit another repair");
            policy.finish(attempt, now, false);
            check(policy.tryBegin(now + delay - 1, true, false, false, true) == null,
                    "must respect exponential retry cooldown");
            now += delay;
        }
        check(policy.tryBegin(now, true, false, false, true) != null,
                "persistent failure remains recoverable after maximum cooldown");

        NativeRecoveryPolicy bypassPolicy = new NativeRecoveryPolicy();
        check(bypassPolicy.beginControlPlaneBypass(true, false, false) == null,
                "authorization must not suspend a VPN without running intent");
        bypassPolicy.setWanted(true);
        check(bypassPolicy.beginControlPlaneBypass(false, false, false) == null,
                "authorization must not suspend an already stopped VPN");
        check(bypassPolicy.beginControlPlaneBypass(true, true, false) == null,
                "authorization must preserve a real smart pause");
        check(bypassPolicy.beginControlPlaneBypass(true, false, true) == null,
                "authorization must not cross an active stop");
        Long bypass = bypassPolicy.beginControlPlaneBypass(true, false, false);
        check(bypass != null && bypassPolicy.isControlPlaneBypassCurrent(bypass),
                "a running VPN can pause once for protected control-plane login");
        check(bypassPolicy.finishControlPlaneBypass(bypass),
                "the current login pause must resume the same running intent");
        check(!bypassPolicy.finishControlPlaneBypass(bypass),
                "a completed login pause must not resume twice");

        Long stoppedDuringLogin = bypassPolicy.beginControlPlaneBypass(true, false, false);
        check(stoppedDuringLogin != null, "a later login can start another pause");
        bypassPolicy.cancelIntent();
        check(!bypassPolicy.finishControlPlaneBypass(stoppedDuringLogin),
                "manual stop during login must never be undone");

        bypassPolicy.setWanted(true);
        Long smartPausedDuringLogin = bypassPolicy.beginControlPlaneBypass(true, false, false);
        check(smartPausedDuringLogin != null, "smart-pause race needs an active login pause");
        bypassPolicy.cancelControlPlaneBypass();
        check(!bypassPolicy.finishControlPlaneBypass(smartPausedDuringLogin),
                "a real smart pause during login must remain paused");
        System.out.println("NativeRecoveryPolicy: all behavior checks passed");
    }
}
