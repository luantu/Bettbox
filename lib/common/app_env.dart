const bool showAppEnvironmentMarks = bool.fromEnvironment(
  'SHOW_APP_ENV_BANNER',
  defaultValue: true,
);

bool shouldShowAppEnvironmentMark(
  bool isPre, {
  bool enabled = showAppEnvironmentMarks,
}) {
  return isPre && enabled;
}
