nonisolated enum AgentHookCommandOwnership {
  /// True when the command was installed by Supacode. The trailing
  /// sentinel is the source of truth; legacy patterns cover hooks from
  /// versions before the sentinel existed.
  static func isSupacodeManagedCommand(_ command: String?) -> Bool {
    guard let command else { return false }
    if command.contains(AgentHookSettingsCommand.ownershipMarker) { return true }
    return isLegacyCommand(command)
  }

  /// True for pre-sentinel Supacode hooks. Current commands carry the
  /// sentinel and are NOT legacy.
  static func isLegacyCommand(_ command: String) -> Bool {
    guard !command.contains(AgentHookSettingsCommand.ownershipMarker) else { return false }
    if command.contains(AgentHookSettingsCommand.legacyCLIPathEnvVar)
      && command.contains(AgentHookSettingsCommand.legacyAgentHookMarker)
    {
      return true
    }
    if command.contains(AgentHookSettingsCommand.socketPathEnvVar)
      && command.contains(#"supacode integration event"#)
    {
      return true
    }
    // Pre-envelope hooks carry the verbatim 4-var presence-guard but
    // neither the sentinel nor the CLI shim. The guard is a Supacode-
    // specific fingerprint: a user following the documented single-var
    // `SUPACODE_SOCKET_PATH` pattern won't match. See `envCheck` for the
    // deliberate trade w.r.t. customized-body-with-Supacode-head hooks.
    return command.contains(AgentHookSettingsCommand.envCheck)
  }
}
