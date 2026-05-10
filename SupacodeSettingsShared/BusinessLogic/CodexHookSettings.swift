import Foundation

nonisolated enum CodexHookSettings {
  fileprivate static let busy = AgentHookSettingsCommand.eventCommand(event: .busy, agent: .codex)
  fileprivate static let idle = AgentHookSettingsCommand.eventCommand(event: .idle, agent: .codex)
  fileprivate static let notify = AgentHookSettingsCommand.notificationCommand(agent: .codex)
  fileprivate static let sessionStart = AgentHookSettingsCommand.eventCommand(
    event: .sessionStart, agent: .codex)

  static func progressHooksByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: CodexProgressPayload(),
      invalidConfiguration: CodexHookSettingsError.invalidConfiguration
    )
  }

  static func notificationHooksByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: CodexNotificationPayload(),
      invalidConfiguration: CodexHookSettingsError.invalidConfiguration
    )
  }

  /// See `ClaudeHookSettings.allHooksByEvent` for the rationale.
  static func allHooksByEvent() throws -> [String: [JSONValue]] {
    var merged = try progressHooksByEvent()
    for (event, groups) in try notificationHooksByEvent() {
      merged[event, default: []].append(contentsOf: groups)
    }
    return merged
  }
}

nonisolated enum CodexHookSettingsError: Error {
  case invalidConfiguration
}

// MARK: - Progress hooks.

// Turn-level activity only — Codex doesn't expose PreToolUse/PostToolUse
// at a useful granularity (Bash-only), so a single `busy` at submit and
// a single `idle` at stop is the cleanest model. SessionStart fires on
// the first turn rather than on session open (openai/codex#15266) — the
// badge appears once the user submits a prompt. Codex has no SessionEnd,
// so the badge clears via the pid liveness sweep when Codex exits.
private nonisolated struct CodexProgressPayload: Encodable {
  let hooks: [String: [AgentHookGroup]] = [
    "SessionStart": [
      .init(hooks: [.init(command: CodexHookSettings.sessionStart, timeout: 5)])
    ],
    "UserPromptSubmit": [
      .init(hooks: [.init(command: CodexHookSettings.busy, timeout: 10)])
    ],
    "Stop": [
      .init(hooks: [.init(command: CodexHookSettings.idle, timeout: 10)])
    ],
  ]
}

// MARK: - Notification hooks.

// Codex only supports Stop for meaningful notification content.
private nonisolated struct CodexNotificationPayload: Encodable {
  let hooks: [String: [AgentHookGroup]] = [
    "Stop": [
      .init(hooks: [.init(command: CodexHookSettings.notify, timeout: 10)])
    ]
  ]
}
