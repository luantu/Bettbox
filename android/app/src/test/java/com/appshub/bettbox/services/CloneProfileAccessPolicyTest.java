package com.appshub.bettbox.services;

import java.util.List;
import java.util.Set;

/** Pure JVM behavior tests for preserving HyperOS app clones in the VPN. */
public final class CloneProfileAccessPolicyTest {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        String self = "com.appshub.bettbox.sg";
        String chatgpt = "com.openai.chatgpt";

        CloneProfileAccessPolicy.Plan disabled = CloneProfileAccessPolicy.build(
                false, true, List.of("owner.selected"), List.of(), self,
                CloneProfileAccessPolicy.CloneState.known(Set.of(chatgpt)));
        check(!disabled.applyPackageFilter, "disabled access control must keep the full VPN UID range");

        CloneProfileAccessPolicy.Plan noClone = CloneProfileAccessPolicy.build(
                true, true, List.of("owner.selected"), List.of(), self,
                CloneProfileAccessPolicy.CloneState.none());
        check(noClone.allowedPackages.equals(List.of("owner.selected", self)),
                "a device without clones must preserve the existing allow-list behavior");

        CloneProfileAccessPolicy.Plan allow = CloneProfileAccessPolicy.build(
                true, true, List.of("owner.selected"), List.of(), self,
                CloneProfileAccessPolicy.CloneState.known(Set.of(chatgpt)));
        check(allow.applyPackageFilter, "known clone packages may use the system package filter");
        check(allow.allowedPackages.equals(List.of("owner.selected", self, chatgpt)),
                "allow-list mode must force every cloned package into the VPN");

        CloneProfileAccessPolicy.Plan deny = CloneProfileAccessPolicy.build(
                true, false, List.of(), List.of("owner.direct", chatgpt, self), self,
                CloneProfileAccessPolicy.CloneState.known(Set.of(chatgpt)));
        check(deny.disallowedPackages.equals(List.of("owner.direct")),
                "deny-list mode must never exclude a cloned package or Bettbox itself");

        CloneProfileAccessPolicy.Plan unavailable = CloneProfileAccessPolicy.build(
                true, true, List.of("owner.selected"), List.of(), self,
                CloneProfileAccessPolicy.CloneState.unavailable());
        check(!unavailable.applyPackageFilter,
                "an unreadable active clone profile must disable the package filter to prevent direct leaks");

        System.out.println("CloneProfileAccessPolicy: all behavior checks passed");
    }
}
