/// Hook events emitted via the JSON envelope path. Mirrors the wire-side
/// `AgentHookEvent.EventName` cases — duplicated here because that type
/// lives in the main app target and this command builder needs to compile
/// in `SupacodeSettingsShared`. `notification` is excluded; it has its own
/// command shape (`notificationCommand`) because it forwards the agent's
/// raw hook payload from stdin.
///
/// Activity events (`busy`, `awaitingInput`, `idle`) are atomic state-set:
/// each one assigns the (surface, agent) activity to that exact value. No
/// counters, no on/off pairs — repeated events are idempotent. The agent's
/// Stop equivalent is the natural reset point that fires `idle`.
nonisolated enum HookEvent: String {
  case sessionStart = "session_start"
  case sessionEnd = "session_end"
  case busy
  case awaitingInput = "awaiting_input"
  case idle
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

  /// Both stdout AND stderr go to /dev/null — Codex parses hook stdout as
  /// structured JSON and would reject the socket ack otherwise.
  private static func managed(_ pipeline: String) -> String {
    "\(envCheck) && \(pipeline) >/dev/null 2>&1 || true \(ownershipMarker)"
  }

  /// Forwards the raw hook event JSON (from stdin) to the socket.
  /// Header: `worktreeID tabID surfaceID agent`.
  static func notificationCommand(agent: SkillAgent) -> String {
    let send =
      #"{ printf '%s \#(agent.rawValue)\n' "\#(ids)"; cat; }"#
      + #" | /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH""#
    return managed(send)
  }

  /// Fires a hook event by writing the JSON envelope directly to the socket
  /// via `nc`. Covers session lifecycle (start/end) and per-turn activity
  /// (`busy`/`awaiting_input`/`idle` — atomic state-set). We don't go
  /// through the bundled `supacode` CLI because hook subshells (especially
  /// Codex's) often don't inherit a PATH containing it, and `2>/dev/null
  /// || true` would swallow the failure. `$PPID` is the agent process —
  /// the hook script is a direct child.
  static func eventCommand(event: HookEvent, agent: SkillAgent) -> String {
    let envelope =
      #"{\"event\":\"\#(event.rawValue)\","#
      + #"\"v\":1,\"agent\":\"\#(agent.rawValue)\","#
      + #"\"surface_id\":\"$SUPACODE_SURFACE_ID\",\"pid\":$PPID}"#
    let send =
      #"printf '%s' "\#(envelope)""#
      + #" | /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH""#
    return managed(send)
  }
}
