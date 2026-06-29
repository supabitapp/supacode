import Foundation

nonisolated enum KimiHookSettings {
  /// Canonical flat list of Kimi hook entries. Each item is one
  /// `[[hooks]]` block in `~/.kimi/config.toml`; Supacode owns exactly
  /// this set. See `ClaudeHookSettings` for the composite-command rationale
  /// (one Supacode-managed entry per slot, so install is an idempotent
  /// prune-and-replace).
  static func canonicalEntries() -> [KimiHookEntry] {
    KimiHooksPayload().entries
  }
}

// MARK: - Hook entry (flat TOML format: event / command / matcher / timeout).

nonisolated struct KimiHookEntry: Equatable, Sendable {
  let event: String
  let command: String
  let matcher: String
  let timeout: Int

  init(event: String, command: String, matcher: String = "", timeout: Int) {
    if command.isEmpty {
      assertionFailure("Kimi hook command must not be empty.")
    }
    if timeout <= 0 {
      assertionFailure("Kimi hook timeout must be positive, got \(timeout).")
    }
    self.event = event
    self.command = command
    self.matcher = matcher
    self.timeout = max(1, timeout)
  }
}

// MARK: - Hook payload.

// Kimi stores hooks as `[[hooks]]` array-of-tables in `~/.kimi/config.toml`
// with PascalCase event names matching Claude's set, so the busy/idle/
// awaitingInput mapping mirrors `ClaudeHooksPayload`. The
// `AskUserQuestion|ExitPlanMode` matcher is reused from Claude and assumed
// inert on Kimi today, since it exposes no such tools. Revisit if Kimi adds
// matching tool names.
private nonisolated struct KimiHooksPayload {
  static let awaitingInputToolMatcher = "AskUserQuestion|ExitPlanMode"

  private static let busy = AgentHookSettingsCommand.compositeCommand(
    events: [.busy], forwardStdinAsNotification: false, agent: .kimi, )
  private static let idle = AgentHookSettingsCommand.compositeCommand(
    events: [.idle], forwardStdinAsNotification: false, agent: .kimi, )
  private static let awaitingInputAndNotify = AgentHookSettingsCommand.compositeCommand(
    events: [.awaitingInput], forwardStdinAsNotification: true, agent: .kimi, )
  private static let awaitingInput = AgentHookSettingsCommand.compositeCommand(
    events: [.awaitingInput], forwardStdinAsNotification: false, agent: .kimi, )
  private static let idleAndNotify = AgentHookSettingsCommand.compositeCommand(
    events: [.idle], forwardStdinAsNotification: true, agent: .kimi, )
  private static let sessionStart = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionStart], forwardStdinAsNotification: false, agent: .kimi, )
  private static let sessionEndAndIdle = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionEnd, .idle], forwardStdinAsNotification: false, agent: .kimi, )

  let entries: [KimiHookEntry] = [
    KimiHookEntry(event: "SessionStart", command: Self.sessionStart, timeout: 5),
    KimiHookEntry(event: "UserPromptSubmit", command: Self.busy, timeout: 10),
    KimiHookEntry(event: "PreToolUse", command: Self.busy, timeout: 5),
    KimiHookEntry(
      event: "PreToolUse", command: Self.awaitingInput,
      matcher: Self.awaitingInputToolMatcher, timeout: 5, ),
    KimiHookEntry(event: "PostToolUse", command: Self.idle, timeout: 5),
    KimiHookEntry(event: "Notification", command: Self.awaitingInputAndNotify, timeout: 10),
    KimiHookEntry(event: "Stop", command: Self.idleAndNotify, timeout: 10),
    KimiHookEntry(event: "SessionEnd", command: Self.sessionEndAndIdle, timeout: 5),
  ]
}
