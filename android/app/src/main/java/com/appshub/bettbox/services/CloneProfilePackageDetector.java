package com.appshub.bettbox.services;

import android.content.Context;
import android.content.pm.LauncherActivityInfo;
import android.content.pm.LauncherApps;
import android.content.pm.LauncherUserInfo;
import android.os.Build;
import android.os.Process;
import android.os.UserHandle;
import android.os.UserManager;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/** Reads launchable packages installed in Android app-clone profiles. */
public final class CloneProfilePackageDetector {
    private static final int XIAOMI_XSPACE_USER_ID = 999;

    private CloneProfilePackageDetector() {}

    public static CloneProfileAccessPolicy.CloneState detect(Context context) {
        LauncherApps launcherApps = context.getSystemService(LauncherApps.class);
        if (launcherApps == null) return CloneProfileAccessPolicy.CloneState.unavailable();

        final List<UserHandle> profiles;
        try {
            profiles = launcherApps.getProfiles();
        } catch (RuntimeException error) {
            return CloneProfileAccessPolicy.CloneState.unavailable();
        }

        UserHandle current = Process.myUserHandle();
        Set<String> packages = new LinkedHashSet<>();
        boolean cloneProfileFound = false;
        for (UserHandle profile : profiles) {
            if (profile.equals(current) || !isCloneProfile(launcherApps, profile)) continue;
            cloneProfileFound = true;
            final List<LauncherActivityInfo> activities;
            try {
                activities = launcherApps.getActivityList(null, profile);
            } catch (RuntimeException error) {
                return CloneProfileAccessPolicy.CloneState.unavailable();
            }
            for (LauncherActivityInfo activity : activities) {
                String packageName = activity.getApplicationInfo().packageName;
                if (packageName != null && !packageName.trim().isEmpty()) packages.add(packageName);
            }
        }
        if (!cloneProfileFound) return CloneProfileAccessPolicy.CloneState.none();
        if (packages.isEmpty()) return CloneProfileAccessPolicy.CloneState.unavailable();
        return CloneProfileAccessPolicy.CloneState.known(packages);
    }

    private static boolean isCloneProfile(LauncherApps launcherApps, UserHandle user) {
        if (Build.VERSION.SDK_INT >= 35) {
            try {
                LauncherUserInfo info = launcherApps.getLauncherUserInfo(user);
                if (info != null) {
                    return UserManager.USER_TYPE_PROFILE_CLONE.equals(info.getUserType());
                }
            } catch (RuntimeException ignored) {
                // Fall through to Xiaomi's stable XSpace user identifier.
            }
        }
        String manufacturer = Build.MANUFACTURER.toLowerCase(Locale.ROOT);
        boolean xiaomiFamily = manufacturer.equals("xiaomi") || manufacturer.equals("redmi") ||
                manufacturer.equals("poco");
        return xiaomiFamily && user.getIdentifier() == XIAOMI_XSPACE_USER_ID;
    }
}
