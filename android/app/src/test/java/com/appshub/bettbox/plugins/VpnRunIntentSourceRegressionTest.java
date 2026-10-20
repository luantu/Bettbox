package com.appshub.bettbox.plugins;

import java.nio.file.Files;
import java.nio.file.Path;

public final class VpnRunIntentSourceRegressionTest {
    public static void main(String[] args) throws Exception {
        String controller = read("lib/controller.dart");
        String main = read("lib/main.dart");
        String state = read("lib/state.dart");
        String servicePlugin = read(
            "android/app/src/main/kotlin/com/appshub/bettbox/plugins/ServicePlugin.kt");
        String bootReceiver = read(
            "android/app/src/main/kotlin/com/appshub/bettbox/receivers/BootReceiver.kt");
        String packageReceiver = read(
            "android/app/src/main/kotlin/com/appshub/bettbox/receivers/PackageReplacedReceiver.kt");

        require(controller.contains("shouldStartVpnAtStartup("),
            "app startup must consult the persisted run intent");
        require(state.contains("await setVpnRunIntent(false)"),
            "foreground manual stop must persist the stop intent first");
        require(main.contains("await globalState.setVpnRunIntent(false)"),
            "background tile stop must persist the stop intent");
        require(main.contains("allowsAutomaticVpnRestart(lastRunIntent)"),
            "silent boot must honor the explicit stop intent");
        require(servicePlugin.contains("VpnRunIntentStore.write("),
            "native service start and stop must mirror user intent");
        require(bootReceiver.contains("VpnRunIntentStore.allowsAutomaticStart(context)"),
            "boot receiver must not bypass an explicit stop");
        require(packageReceiver.contains("VpnRunIntentStore.allowsAutomaticStart(context)"),
            "package update must not bypass an explicit stop");
    }

    private static String read(String path) throws Exception {
        return Files.readString(Path.of(path));
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
