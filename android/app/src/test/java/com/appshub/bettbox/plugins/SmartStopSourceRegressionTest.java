package com.appshub.bettbox.plugins;

import java.nio.file.Files;
import java.nio.file.Path;

public final class SmartStopSourceRegressionTest {
    public static void main(String[] args) throws Exception {
        String source = Files.readString(Path.of(
            "android/app/src/main/kotlin/com/appshub/bettbox/plugins/VpnPlugin.kt"));

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
