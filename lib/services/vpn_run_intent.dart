const vpnUserRunIntentPreferenceKey = 'vpn_user_run_intent';
const vpnUserRunIntentMigratedPreferenceKey = 'vpn_user_run_intent_migrated';
const vpnRuntimePreferenceKey = 'is_vpn_running';

bool allowsAutomaticVpnRestart(bool? lastRunIntent) => lastRunIntent != false;

bool? resolveVpnUserRunIntent({
  required bool? explicitIntent,
  required bool migrationComplete,
  required bool? legacyRuntimeState,
}) {
  if (explicitIntent != null) return explicitIntent;
  if (migrationComplete) return null;
  return legacyRuntimeState;
}

bool shouldStartVpnAtStartup({
  required bool hasProfile,
  required bool alreadyRunning,
  required bool autoRun,
  required bool? lastRunIntent,
}) {
  if (!hasProfile) return false;
  if (alreadyRunning) return true;
  return autoRun && allowsAutomaticVpnRestart(lastRunIntent);
}
