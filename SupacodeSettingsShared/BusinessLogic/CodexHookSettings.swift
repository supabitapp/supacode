import Foundation

nonisolated enum CodexHookSettings {
  fileprivate static let busyOn = AgentHookSettingsCommand.busyCommand(active: true)
  fileprivate static let busyOff = AgentHookSettingsCommand.busyCommand(active: false)
  fileprivate static let notify = AgentHookSettingsCommand.notificationCommand(agent: "codex")
  fileprivate static let sessionStart = AgentHookSettingsCommand.sessionEventCommand(
    event: "session_start", agent: "codex")

  static func progressHookGroupsByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: CodexProgressPayload(),
      invalidConfiguration: CodexHookSettingsError.invalidConfiguration
    )
  }

  static func notificationHookGroupsByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: CodexNotificationPayload(),
      invalidConfiguration: CodexHookSettingsError.invalidConfiguration
    )
  }

  /// See `ClaudeHookSettings.allHookGroupsByEvent` for the rationale.
  static func allHookGroupsByEvent() throws -> [String: [JSONValue]] {
    var merged = try progressHookGroupsByEvent()
    for (event, groups) in try notificationHookGroupsByEvent() {
      merged[event, default: []].append(contentsOf: groups)
    }
    return merged
  }
}

nonisolated enum CodexHookSettingsError: Error {
  case invalidConfiguration
}

// MARK: - Progress hooks.

// Codex fires UserPromptSubmit, Stop, PreToolUse (Bash), and SessionStart.
// Submit/Stop drive busy tracking; SessionStart feeds the agent presence
// badge — Codex fires it on the first turn rather than on session open
// (see openai/codex#15266), so the badge appears once the user submits a
// prompt. Codex has no SessionEnd, so the badge clears via the pid
// liveness sweep when Codex exits.
private nonisolated struct CodexProgressPayload: Encodable {
  let hooks: [String: [AgentHookGroup]] = [
    "SessionStart": [
      .init(hooks: [.init(command: CodexHookSettings.sessionStart, timeout: 5)])
    ],
    "UserPromptSubmit": [
      .init(hooks: [
        .init(command: CodexHookSettings.busyOn, timeout: 10)
      ])
    ],
    "Stop": [
      .init(hooks: [.init(command: CodexHookSettings.busyOff, timeout: 10)])
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
