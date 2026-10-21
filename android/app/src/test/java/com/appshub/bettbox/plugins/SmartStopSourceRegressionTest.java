package com.appshub.bettbox.plugins;

import java.nio.file.Files;
import java.nio.file.Path;

public final class SmartStopSourceRegressionTest {
    public static void main(String[] args) throws Exception {
        String source = Files.readString(Path.of(
            "android/app/src/main/kotlin/com/appshub/bettbox/plugins/VpnPlugin.kt"));
        String smartAutoStop = Files.readString(Path.of(
            "lib/manager/smart_auto_stop_manager.dart"));
        String serviceMain = Files.readString(Path.of("lib/main.dart"));
        String compatibility = Files.readString(Path.of(
            "android/app/src/main/kotlin/com/appshub/bettbox/services/CompatibilityAppManager.kt"));
        String manifest = Files.readString(Path.of(
            "android/app/src/main/AndroidManifest.xml"));
        String launchActivity = Files.readString(Path.of(
            "android/app/src/main/kotlin/com/appshub/bettbox/CompatibilityLaunchActivity.kt"));

        String smartStop = methodBody(source, "fun handleSmartStop()");
        String smartResume = methodBody(
            source,
            "fun handleSmartResume(options: VpnOptions): Boolean");

        require(smartStop.contains("Core.stopTun()"),
            "smart stop must tear down the Android TUN");
        require(smartResume.contains("performStartCore("),
            "smart resume must rebuild the Android TUN");

        // Core.suspended(1) reflects into private WireGuard fields. On the SG
        // core that panics the Go runtime and aborts the Android process.
        require(!smartStop.contains("Core.suspended("),
            "smart stop must not invoke the unsafe core suspend path");
        require(!smartResume.contains("Core.suspended("),
            "smart resume must not invoke the unsafe core suspend path");
        require(smartAutoStop.contains("isCompatibilityPaused()"),
            "foreground smart-stop must not resume a compatibility-owned pause");
        require(serviceMain.contains("isCompatibilityPaused()"),
            "service-isolate smart-stop must not resume a compatibility-owned pause");
        require(compatibility.contains("com.miui.home") &&
                compatibility.contains("INSTALL_SHORTCUT"),
            "HyperOS must receive a legacy launcher shortcut fallback");
        require(manifest.contains("com.android.launcher.permission.INSTALL_SHORTCUT"),
            "the HyperOS shortcut fallback requires launcher install permission");
        require(compatibility.contains("UUID.randomUUID()") &&
                compatibility.contains("launchFromShortcut"),
            "exported compatibility shortcuts must carry an unpredictable private token");
        require(launchActivity.contains("EXTRA_SHORTCUT_TOKEN") &&
                launchActivity.contains("launchFromShortcut"),
            "the exported compatibility Activity must reject calls without its private token");
        require(compatibility.contains("VpnPlugin.setSmartStopped(false)") &&
                compatibility.contains("VpnRunIntentStore.write"),
            "keep-stopped must clear SmartStop ownership and persist explicit user intent");
        require(compatibility.contains("IMPORTANCE_NONE"),
            "manual notification fallback must reject a disabled compatibility channel");
        require(smartAutoStop.contains("getVpnRunIntent(reload: true)"),
            "foreground SmartAutoStop resume must honor explicit user stop");
        require(serviceMain.contains("getVpnRunIntent(reload: true)"),
            "service-isolate SmartAutoStop resume must honor explicit user stop");
    }

    private static String methodBody(String source, String signature) {
        int start = source.indexOf(signature);
        require(start >= 0, "missing method: " + signature);
        int bodyStart = source.indexOf('{', start);
        require(bodyStart >= 0, "missing method body: " + signature);
        int depth = 0;
        for (int index = bodyStart; index < source.length(); index++) {
            char current = source.charAt(index);
            if (current == '{') depth++;
            if (current == '}' && --depth == 0) {
                return source.substring(bodyStart, index + 1);
            }
        }
        throw new AssertionError("unterminated method: " + signature);
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
