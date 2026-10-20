const vpnRunIntentPreferenceKey = 'is_vpn_running';

bool allowsAutomaticVpnRestart(bool? lastRunIntent) => lastRunIntent != false;

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
