package com.appshub.bettbox.services;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/** Keeps packages installed in an app-clone profile inside the Android VPN. */
public final class CloneProfileAccessPolicy {
    private CloneProfileAccessPolicy() {}

    public enum State { NONE, KNOWN, UNAVAILABLE }

    public static final class CloneState {
        public final State state;
        public final Set<String> packages;

        private CloneState(State state, Set<String> packages) {
            this.state = state;
            this.packages = Collections.unmodifiableSet(new LinkedHashSet<>(packages));
        }

        public static CloneState none() {
            return new CloneState(State.NONE, Collections.emptySet());
        }

        public static CloneState known(Set<String> packages) {
            return new CloneState(State.KNOWN, packages);
        }

        public static CloneState unavailable() {
            return new CloneState(State.UNAVAILABLE, Collections.emptySet());
        }

        public static CloneState noVisibleProfile(boolean cloneCapableVendor) {
            return cloneCapableVendor ? unavailable() : none();
        }
    }

    public static final class Plan {
        public final boolean applyPackageFilter;
        public final List<String> allowedPackages;
        public final List<String> disallowedPackages;
        public final State cloneState;

        private Plan(boolean applyPackageFilter, List<String> allowedPackages,
                     List<String> disallowedPackages, State cloneState) {
            this.applyPackageFilter = applyPackageFilter;
            this.allowedPackages = Collections.unmodifiableList(new ArrayList<>(allowedPackages));
            this.disallowedPackages = Collections.unmodifiableList(new ArrayList<>(disallowedPackages));
            this.cloneState = cloneState;
        }
    }

    public static Plan build(boolean enabled, boolean allowMode,
                             List<String> accepted, List<String> rejected,
                             String selfPackage, CloneState clones) {
        if (!enabled || clones.state == State.UNAVAILABLE) {
            return new Plan(false, Collections.emptyList(), Collections.emptyList(), clones.state);
        }

        LinkedHashSet<String> clonePackages = clean(clones.packages);
        if (allowMode) {
            LinkedHashSet<String> allowed = clean(accepted);
            addNonBlank(allowed, selfPackage);
            allowed.addAll(clonePackages);
            return new Plan(true, new ArrayList<>(allowed), Collections.emptyList(), clones.state);
        }

        LinkedHashSet<String> disallowed = clean(rejected);
        disallowed.remove(selfPackage);
        disallowed.removeAll(clonePackages);
        return new Plan(true, Collections.emptyList(), new ArrayList<>(disallowed), clones.state);
    }

    private static LinkedHashSet<String> clean(Iterable<String> values) {
        LinkedHashSet<String> result = new LinkedHashSet<>();
        for (String value : values) addNonBlank(result, value);
        return result;
    }

    private static void addNonBlank(Set<String> target, String value) {
        if (value != null && !value.trim().isEmpty()) target.add(value);
    }
}
