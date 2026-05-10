/// Session-lifecycle event names emitted by `sessionEventCommand`. Mirrors
/// the wire-side `AgentHookEvent.EventName.sessionStart/sessionEnd` cases —
/// duplicated here because that type lives in the main app target and this
/// command builder needs to compile in `SupacodeSettingsShared`.
nonisolated enum SessionEvent: String {
  case sessionStart = "session_start"
  case sessionEnd = "session_end"
}

nonisolated enum AgentHookSettingsCommand {
  /// Sentinel comment appended to every Supacode-installed hook command.
  /// `AgentHookCommandOwnership` uses this — and ONLY this — to identify
  /// managed commands. `SUPACODE_SOCKET_PATH` is documented public API
  /// (CLI skill env table, Pi extension example, deeplink reference), so
  /// matching on the env-var name alone would silently strip user-authored
  /// hooks that legitimately reference it.
  static let ownershipMarker = "# supacode-managed-hook"

  /// Documented public env var. Used as ONE half of the legacy CLI-shim
  /// fingerprint (paired with `supacode integration event`); never matched
  /// alone — user-authored hooks reference it legitimately.
  static let socketPathEnvVar = "SUPACODE_SOCKET_PATH"

  /// Markers present in legacy Supacode hook commands (pre-socket).
  static let legacyCLIPathEnvVar = "SUPACODE_CLI_PATH"
  static let legacyAgentHookMarker = "agent-hook"

  private static let envCheck =
    #"[ -n "${SUPACODE_SOCKET_PATH:-}" ]"#
    + #" && [ -n "${SUPACODE_WORKTREE_ID:-}" ]"#
    + #" && [ -n "${SUPACODE_TAB_ID:-}" ]"#
    + #" && [ -n "${SUPACODE_SURFACE_ID:-}" ]"#

  private static let ids =
    "$SUPACODE_WORKTREE_ID $SUPACODE_TAB_ID $SUPACODE_SURFACE_ID"

  /// Both stdout AND stderr must be redirected — Codex parses hook stdout as structured JSON and would reject the socket ack.
  private static func managed(_ pipeline: String) -> String {
    "\(envCheck) && \(pipeline) >/dev/null 2>&1 || true \(ownershipMarker)"
  }

  /// Sends `worktreeID tabID surfaceID 1|0` over a Unix socket.
  static func busyCommand(active: Bool) -> String {
    let flag = active ? "1" : "0"
    let send =
      #"echo "\#(ids) \#(flag)""#
      + #" | /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH""#
    return managed(send)
  }

  /// Forwards the raw hook event JSON (from stdin) to the socket.
  /// Header: `worktreeID tabID surfaceID agent`.
  static func notificationCommand(agent: SkillAgent) -> String {
    let send =
      #"{ printf '%s \#(agent.rawValue)\n' "\#(ids)"; cat; }"#
      + #" | /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH""#
    return managed(send)
  }

  /// Fires a session lifecycle event by writing the JSON envelope directly
  /// to the socket via `nc`. We don't go through the bundled `supacode` CLI
  /// because hook subshells (especially Codex's) often don't inherit a PATH
  /// containing it, and `2>/dev/null || true` would swallow the failure.
  /// `$PPID` is the agent process — the hook script is a direct child.
  static func sessionEventCommand(event: SessionEvent, agent: SkillAgent) -> String {
    let envelope =
      #"{\"event\":\"\#(event.rawValue)\",\"v\":1,\"agent\":\"\#(agent.rawValue)\",\"surface_id\":\"$SUPACODE_SURFACE_ID\",\"pid\":$PPID}"#
    let send =
      #"printf '%s' "\#(envelope)""#
      + #" | /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH""#
    return managed(send)
  }
}
