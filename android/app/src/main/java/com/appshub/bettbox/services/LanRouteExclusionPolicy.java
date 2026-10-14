package com.appshub.bettbox.services;

import java.net.InetAddress;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;

/** Builds fail-safe Android TUN exclusions for local-device connectivity. */
public final class LanRouteExclusionPolicy {
    private static final List<String> DISCOVERY_ROUTES = Collections.unmodifiableList(Arrays.asList(
            "169.254.0.0/16",
            "224.0.0.0/4",
            "fe80::/10",
            "ff00::/8"));

    private LanRouteExclusionPolicy() {}

    public static List<String> effective(List<String> configured) {
        LinkedHashSet<String> routes = new LinkedHashSet<>();
        for (String value : configured) {
            String route = value == null ? "" : value.trim();
            if (isValidCidr(route)) routes.add(route);
        }
        if (routes.isEmpty()) return Collections.emptyList();
        routes.addAll(DISCOVERY_ROUTES);
        return Collections.unmodifiableList(new ArrayList<>(routes));
    }

    private static boolean isValidCidr(String value) {
        int slash = value.lastIndexOf('/');
        if (slash <= 0 || slash == value.length() - 1) return false;
        String address = value.substring(0, slash);
        final int prefix;
        try {
            prefix = Integer.parseInt(value.substring(slash + 1));
        } catch (NumberFormatException error) {
            return false;
        }
        try {
            if (address.indexOf(':') >= 0) {
                if (!address.matches("[0-9a-fA-F:]+") || prefix < 0 || prefix > 128) return false;
                return InetAddress.getByName(address).getAddress().length == 16;
            }
            if (!address.matches("[0-9.]+") || prefix < 0 || prefix > 32) return false;
            String[] parts = address.split("\\.", -1);
            if (parts.length != 4) return false;
            for (String part : parts) {
                if (part.isEmpty() || Integer.parseInt(part) > 255) return false;
            }
            return InetAddress.getByName(address).getAddress().length == 4;
        } catch (Exception error) {
            return false;
        }
    }
}
