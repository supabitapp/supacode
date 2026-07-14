import Foundation

nonisolated enum ClaudeHookSettings {
  /// Canonical hook map for Claude. One composite command per (event,
  /// matcher) slot keeps the prune-and-replace cycle idempotent.
  static func hooksByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: ClaudeHooksPayload(),
      invalidConfiguration: ClaudeHookSettingsError.invalidConfiguration
    )
  }
}

nonisolated enum ClaudeHookSettingsError: Error {
  case invalidConfiguration
}

// MARK: - Hook payload.

// Atomic state-set: UserPromptSubmit / PreToolUse fire `busy`; PostToolUse
// fires `idle` so the shimmer tracks active tool execution, not the whole turn
// (the socket debounces idle to bridge between-tool gaps). AskUserQuestion /
// ExitPlanMode / Notification overwrite to `awaitingInput`; Stop and SessionEnd
// reset to `idle`. The pid liveness sweep is the safety net for crashed turns.
// Only Claude has tool-level granularity; Codex and Kiro stay turn-level, so
// their shimmer spans the whole turn.
private nonisolated struct ClaudeHooksPayload: Encodable {
  static let awaitingInputToolMatcher = "AskUserQuestion|ExitPlanMode"

  private static let busy = AgentHookSettingsCommand.compositeCommand(
    events: [.busy], forwardStdinAsNotification: false, agent: .claude)
  private static let idle = AgentHookSettingsCommand.compositeCommand(
    events: [.idle], forwardStdinAsNotification: false, agent: .claude)
  private static let awaitingInputAndNotify = AgentHookSettingsCommand.compositeCommand(
    events: [.awaitingInput], forwardStdinAsNotification: true, agent: .claude)
  private static let awaitingInput = AgentHookSettingsCommand.compositeCommand(
    events: [.awaitingInput], forwardStdinAsNotification: false, agent: .claude)
  private static let stop = AgentHookSettingsCommand.claudeStopCommand(agent: .claude)
  // PostCompact is intentionally NOT mapped: compaction finishing is not turn
  // completion. `SessionStart(source: compact)` is what ends the compacting state.
  private static let compacting = AgentHookSettingsCommand.compositeCommand(
    events: [.compacting], forwardStdinAsNotification: false, agent: .claude)
  private static let sessionStart = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionStart], forwardStdinAsNotification: false, agent: .claude)
  private static let sessionEndAndIdle = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionEnd, .idle], forwardStdinAsNotification: false, agent: .claude)

  let hooks: [String: [AgentHookGroup]] = [
    "SessionStart": [
      .init(hooks: [.init(command: Self.sessionStart, timeout: 5)])
    ],
    "UserPromptSubmit": [
      .init(hooks: [.init(command: Self.busy, timeout: 10)])
    ],
    "PreToolUse": [
      .init(matcher: "", hooks: [.init(command: Self.busy, timeout: 5)]),
      // Array-order: matched-by-name fires AFTER matcher-"", so awaiting wins.
      .init(
        matcher: Self.awaitingInputToolMatcher,
        hooks: [.init(command: Self.awaitingInput, timeout: 5)]
      ),
    ],
    "PostToolUse": [
      .init(matcher: "", hooks: [.init(command: Self.idle, timeout: 5)])
    ],
    "Notification": [
      .init(matcher: "", hooks: [.init(command: Self.awaitingInputAndNotify, timeout: 10)])
    ],
    "PreCompact": [
      .init(hooks: [.init(command: Self.compacting, timeout: 5)])
    ],
    "Stop": [
      .init(hooks: [.init(command: Self.stop, timeout: 10)])
    ],
    "SessionEnd": [
      .init(matcher: "", hooks: [.init(command: Self.sessionEndAndIdle, timeout: 5)])
    ],
  ]
}
