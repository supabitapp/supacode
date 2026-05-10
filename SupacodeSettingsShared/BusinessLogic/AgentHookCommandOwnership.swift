nonisolated enum AgentHookCommandOwnership {
  /// Returns `true` when the command was installed by Supacode. Matches
  /// the trailing sentinel comment first (current installs) and falls
  /// back to legacy markers for hooks installed by older versions —
  /// matching `SUPACODE_SOCKET_PATH` alone would silently strip
  /// user-authored hooks that legitimately reference the documented
  /// public env var.
  static func isSupacodeManagedCommand(_ command: String?) -> Bool {
    guard let command else { return false }
    if command.contains(AgentHookSettingsCommand.ownershipMarker) { return true }
    return isLegacyCommand(command)
  }

  /// Returns `true` for commands from older Supacode versions (pre-
  /// sentinel-marker, including the legacy CLI-driven era). Current
  /// commands carry the sentinel and are NOT legacy.
  static func isLegacyCommand(_ command: String) -> Bool {
    guard !command.contains(AgentHookSettingsCommand.ownershipMarker) else { return false }
    if command.contains(AgentHookSettingsCommand.legacyCLIPathEnvVar)
      && command.contains(AgentHookSettingsCommand.legacyAgentHookMarker)
    {
      return true
    }
    // Match the legacy CLI shim so a fresh install prunes it instead of stacking duplicates.
    return command.contains(AgentHookSettingsCommand.socketPathEnvVar)
      && command.contains(#"supacode integration event"#)
  }
}
