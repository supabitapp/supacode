/// Hook events emitted via the JSON envelope path. Activity events
/// (`busy`, `awaitingInput`, `idle`) are atomic state-set — each fires
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

  /// Verbatim 4-var presence-guard at the head of every Supacode-installed
  /// hook. Carried forward unchanged across every command-shape revision,
  /// so it doubles as the pre-sentinel legacy fingerprint. A user-authored
  /// hook following the documented `SUPACODE_SOCKET_PATH`-only pattern
  /// (single-var check) does not match. A user who copied this guard
  /// verbatim AND removed the trailing sentinel intentionally would be
  /// treated as legacy — that's the deliberate trade for catching every
  /// pre-envelope shape of older Supacode hook.
  static let envCheck =
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

  /// Builds a single shell command that fires every `event` envelope and
  /// optionally forwards stdin as a notification — all under one envCheck
  /// guard with one sentinel. Stdin is consumed once via `payload=$(cat)`
  /// so the same payload can be relayed after the fixed envelopes. The
  /// precondition rejects a no-op invocation because the empty-empty
  /// fallthrough would otherwise emit `{ ; }` (shell syntax error masked
  /// by `|| true`).
  static func compositeCommand(
    events: [HookEvent],
    forwardStdinAsNotification: Bool,
    agent: SkillAgent
  ) -> String {
    precondition(
      !events.isEmpty || forwardStdinAsNotification,
      "compositeCommand needs at least one side-effect (events or stdin forward).",
    )
    if events.count == 1, !forwardStdinAsNotification {
      return managed(envelopePipeline(event: events[0], agent: agent))
    }
    if events.isEmpty, forwardStdinAsNotification {
      return managed(notifyPipeline(agent: agent, payloadExpr: nil))
    }
    var steps: [String] = []
    if forwardStdinAsNotification { steps.append("payload=$(cat)") }
    for event in events {
      steps.append(envelopePipeline(event: event, agent: agent))
    }
    if forwardStdinAsNotification {
      steps.append(notifyPipeline(agent: agent, payloadExpr: #""$payload""#))
    }
    return managed("{ \(steps.joined(separator: "; ")); }")
  }

  private static func envelopePipeline(event: HookEvent, agent: SkillAgent) -> String {
    let envelope =
      #"{\"event\":\"\#(event.rawValue)\","#
      + #"\"v\":1,\"agent\":\"\#(agent.rawValue)\","#
      + #"\"surface_id\":\"$SUPACODE_SURFACE_ID\",\"pid\":$PPID}"#
    return #"printf '%s' "\#(envelope)" | /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH""#
  }

  /// `payloadExpr == nil` → forward stdin live via `cat`. Non-nil → relay
  /// a previously-stashed shell expression (so the composite path can
  /// consume stdin once and reuse it after event envelopes).
  private static func notifyPipeline(agent: SkillAgent, payloadExpr: String?) -> String {
    let body: String
    if let payloadExpr {
      body = #"printf '%s' \#(payloadExpr)"#
    } else {
      body = "cat"
    }
    return
      #"{ printf '%s \#(agent.rawValue)\n' "\#(ids)"; \#(body); }"#
      + #" | /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH""#
  }
}
