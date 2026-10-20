const vpnUserRunIntentPreferenceKey = 'vpn_user_run_intent';
const vpnUserRunIntentMigratedPreferenceKey = 'vpn_user_run_intent_migrated';
const vpnRuntimePreferenceKey = 'is_vpn_running';

bool allowsAutomaticVpnRestart(bool? lastRunIntent) => lastRunIntent != false;

bool shouldStartAutomaticVpnService({
  required bool autoRun,
  required bool? lastRunIntent,
}) {
  if (lastRunIntent != null) return lastRunIntent;
  return autoRun;
}

bool? resolveVpnUserRunIntent({
  required bool? explicitIntent,
}) {
  // The legacy runtime flag was also cleared by failures and internal stops,
  // so it cannot safely be promoted to an explicit user choice.
  return explicitIntent;
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
