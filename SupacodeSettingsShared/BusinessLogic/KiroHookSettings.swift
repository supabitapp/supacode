import Foundation

nonisolated enum KiroHookSettings {
  fileprivate static let busyOn = AgentHookSettingsCommand.busyCommand(active: true)
  fileprivate static let busyOff = AgentHookSettingsCommand.busyCommand(active: false)
  fileprivate static let notify = AgentHookSettingsCommand.notificationCommand(agent: "kiro")
  fileprivate static let defaultTimeoutMs = 10_000

  static func progressHookEntriesByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: KiroProgressPayload(),
      invalidConfiguration: KiroHookSettingsError.invalidConfiguration
    )
  }

  static func notificationHookEntriesByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: KiroNotificationPayload(),
      invalidConfiguration: KiroHookSettingsError.invalidConfiguration
    )
  }
}

nonisolated enum KiroHookSettingsError: Error {
  case invalidConfiguration
}

// MARK: - Kiro hook entry (flat format: command + timeout_ms, no type/group wrapper).

nonisolated struct KiroHookEntry: Encodable {
  let command: String
  let timeoutMs: Int

  init(command: String, timeoutMs: Int) {
    if command.isEmpty {
      assertionFailure("Kiro hook command must not be empty.")
    }
    if timeoutMs <= 0 {
      assertionFailure("Kiro hook timeout_ms must be positive, got \(timeoutMs).")
    }
    self.command = command
    self.timeoutMs = max(1, timeoutMs)
  }

  enum CodingKeys: String, CodingKey {
    case command
    case timeoutMs = "timeout_ms"
  }
}

// MARK: - Progress hooks.

// Kiro uses camelCase event names ("userPromptSubmit", "stop") unlike
// Claude/Codex which use PascalCase ("UserPromptSubmit", "Stop").
private nonisolated struct KiroProgressPayload: Encodable {
  let hooks: [String: [KiroHookEntry]] = [
    "userPromptSubmit": [
      KiroHookEntry(command: KiroHookSettings.busyOn, timeoutMs: KiroHookSettings.defaultTimeoutMs)
    ],
    "stop": [
      KiroHookEntry(command: KiroHookSettings.busyOff, timeoutMs: KiroHookSettings.defaultTimeoutMs)
    ],
  ]
}

// MARK: - Notification hooks.

private nonisolated struct KiroNotificationPayload: Encodable {
  let hooks: [String: [KiroHookEntry]] = [
    "stop": [
      KiroHookEntry(command: KiroHookSettings.notify, timeoutMs: KiroHookSettings.defaultTimeoutMs)
    ]
  ]
}
