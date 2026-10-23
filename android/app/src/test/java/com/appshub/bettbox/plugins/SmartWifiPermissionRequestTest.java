package com.appshub.bettbox.plugins;

import java.util.ArrayList;
import java.util.List;

public final class SmartWifiPermissionRequestTest {
    public static void main(String[] args) {
        String fine = "android.permission.ACCESS_FINE_LOCATION";
        String coarse = "android.permission.ACCESS_COARSE_LOCATION";
        if (!SmartWifiPermissionRequest.isPreciseGrant(new String[]{coarse, fine}, new int[]{0, 0}, true)) {
            throw new AssertionError("precise grant must resolve true after real callback and readback");
        }
        if (!SmartWifiPermissionRequest.isPreciseGrant(new String[]{fine, coarse}, new int[]{0, -1}, true)) {
            throw new AssertionError("callback permission order must not matter");
        }
        if (SmartWifiPermissionRequest.isPreciseGrant(new String[]{coarse, fine}, new int[]{0, -1}, false)
                || SmartWifiPermissionRequest.isPreciseGrant(new String[]{coarse}, new int[]{0}, true)
                || SmartWifiPermissionRequest.isPreciseGrant(new String[]{fine}, new int[]{0}, false)
                || SmartWifiPermissionRequest.isPreciseGrant(new String[]{fine}, new int[]{}, true)
                || SmartWifiPermissionRequest.isPreciseGrant(new String[]{}, new int[]{}, true)) {
            throw new AssertionError("approximate, denied, revoked, truncated and cancelled results resolve false");
        }
        SmartWifiPermissionRequest request = new SmartWifiPermissionRequest();
        List<Boolean> replies = new ArrayList<>();
        if (!request.begin(replies::add)) throw new AssertionError("first request must launch permission UI");
        if (request.begin(replies::add)) throw new AssertionError("concurrent callers must share the prompt");
        if (!replies.isEmpty()) throw new AssertionError("must wait for actual Android result");
        request.complete(true);
        if (!replies.equals(List.of(true, true))) throw new AssertionError("reply to every pending caller");
        request.complete(false);
        if (replies.size() != 2) throw new AssertionError("late callback must not reply twice");
        if (!request.begin(replies::add)) throw new AssertionError("a new request can start");
        request.complete(false); // Detach/cancel uses the same single-completion path.
        request.complete(true);
        if (!replies.equals(List.of(true, true, false))) throw new AssertionError("detach resolves false exactly once");
        System.out.println("SmartWifiPermissionRequest: all behavior checks passed");
    }
}
