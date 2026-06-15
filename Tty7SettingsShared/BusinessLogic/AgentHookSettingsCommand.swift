/// Hook events emitted via the JSON envelope path. Activity events
/// (`busy`, `awaitingInput`, `idle`) are atomic state-set. Each fires
/// the corresponding (surface, agent) activity directly; repeated events
/// are idempotent. The notification leg is composed in alongside an
/// envelope by `compositeCommand(forwardStdinAsNotification:)`.
nonisolated enum HookEvent: String {
  case sessionStart = "session_start"
  case sessionEnd = "session_end"
  case busy
  case awaitingInput = "awaiting_input"
  case idle
}

nonisolated enum AgentHookSettingsCommand {
  /// Sentinel comment appended to every tty7-installed hook command.
  /// `AgentHookCommandOwnership` uses this (and ONLY this) to identify
  /// managed commands. `TTY7_SOCKET_PATH` is documented public API
  /// (CLI skill env table, Pi extension example, deeplink reference), so
  /// matching on the env-var name alone would silently strip user-authored
  /// hooks that legitimately reference it.
  static let ownershipMarker = "# tty7-managed-hook"

  /// Documented public env var. Used as ONE half of the legacy CLI-shim
  /// fingerprint (paired with `tty7 integration event`); never matched
  /// alone. User-authored hooks reference it legitimately.
  static let socketPathEnvVar = "TTY7_SOCKET_PATH"

  /// Markers present in legacy tty7 hook commands (pre-socket).
  static let legacyCLIPathEnvVar = "TTY7_CLI_PATH"
  static let legacyAgentHookMarker = "agent-hook"

  /// Verbatim 4-var presence-guard at the head of every tty7-installed
  /// hook. Carried forward unchanged across every command-shape revision,
  /// so it doubles as the pre-sentinel legacy fingerprint. A user-authored
  /// hook following the documented `TTY7_SOCKET_PATH`-only pattern
  /// (single-var check) does not match. A user who copied this guard
  /// verbatim AND removed the trailing sentinel intentionally would be
  /// treated as legacy. That's the deliberate trade for catching every
  /// pre-envelope shape of older tty7 hook.
  static let envCheck =
    #"[ -n "${TTY7_SOCKET_PATH:-}" ]"#
    + #" && [ -n "${TTY7_WORKTREE_ID:-}" ]"#
    + #" && [ -n "${TTY7_TAB_ID:-}" ]"#
    + #" && [ -n "${TTY7_SURFACE_ID:-}" ]"#

  /// Composes the OSC 3008 hook command: one guard, then (once that passes) the
  /// tty resolve plus a presence emit per event and/or a notify emit, all in a
  /// single brace group whose output is suppressed. Guarding first keeps the
  /// command truly inert outside tty7 (no `ps` runs when the surface id is
  /// unset). The precondition rejects a no-op invocation that would emit nothing.
  static func compositeCommand(
    events: [HookEvent],
    forwardStdinAsNotification: Bool,
    agent: SkillAgent
  ) -> String {
    precondition(
      !events.isEmpty || forwardStdinAsNotification,
      "compositeCommand needs at least one side-effect (events or stdin forward).",
    )
    var steps: [String] = [AgentPresenceOSC.ttyResolveSnippet]
    steps += events.map { AgentPresenceOSC.emitShell(event: $0, agent: agent) }
    if forwardStdinAsNotification { steps.append(AgentPresenceOSC.emitNotifyShell(agent: agent)) }
    return "\(oscGuardExpr) && { \(steps.joined(separator: "; ")); } >/dev/null 2>&1 || true \(ownershipMarker)"
  }

  /// Guard for the OSC command: a surface id present (the no-op-outside-tty7
  /// gate). Fires both locally and over SSH; the pid suffix inside the presence
  /// emit is what's gated on the socket path, not the emission itself.
  private static var oscGuardExpr: String {
    #"[ -n "${\#(AgentPresenceOSC.surfaceEnvVar):-}" ]"#
  }
}
