package com.appshub.bettbox.plugins;

/** Standalone behavioral tests: no Android runtime, credentials or network. */
public final class UnderlyingNetworkPathPolicyTest {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        UnderlyingNetworkPathPolicy policy = new UnderlyingNetworkPathPolicy();

        check(!policy.update(205L, "rmnet_data3|10.0.0.2/30|10.0.0.1", true),
                "the first physical path must establish a baseline only");
        check(!policy.update(205L, "rmnet_data3|10.0.0.2/30|10.0.0.1", true),
                "an unchanged path must not churn CorpLink tunnels");
        check(policy.update(205L, "rmnet_data3|10.0.1.2/30|10.0.1.1", true),
                "same cellular handle with a changed address or gateway must recover");
        check(policy.update(215L, "wlan0|192.168.110.8/24|192.168.110.1", true),
                "a new underlying Network handle must recover");

        check(!policy.update(216L, "wlan0|192.168.111.8/24|192.168.111.1", false),
                "a stopped VPN must update its baseline without reconnecting");
        check(!policy.update(216L, "wlan0|192.168.111.8/24|192.168.111.1", true),
                "starting on the already-recorded path must not reconnect again");

        policy.reset();
        check(!policy.update(205L, "rmnet_data3|10.0.2.2/30|10.0.2.1", true),
                "reset must discard the old path and establish a fresh baseline");
        System.out.println("UnderlyingNetworkPathPolicy: all behavior checks passed");
    }
}
