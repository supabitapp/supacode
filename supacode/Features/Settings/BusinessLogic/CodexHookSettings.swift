import Foundation

nonisolated enum CodexHookSettings {
  fileprivate static let busyOn = AgentHookSettingsCommand.busyCommand(active: true)
  fileprivate static let busyOff = AgentHookSettingsCommand.busyCommand(active: false)
  fileprivate static let notify = AgentHookSettingsCommand.notificationCommand(agent: "codex")

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
}

nonisolated enum CodexHookSettingsError: Error {
  case invalidConfiguration
}

// MARK: - Progress hooks.

// Codex fires UserPromptSubmit, Stop, PreToolUse (Bash), and SessionStart.
// Only Submit/Stop are used for busy tracking.
private nonisolated struct CodexProgressPayload: Encodable {
  let hooks: [String: [AgentHookGroup]] = [
    "UserPromptSubmit": [
      .init(hooks: [
        .init(command: CodexHookSettings.busyOn, timeout: 10)
      ]),
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
    ],
  ]
}
