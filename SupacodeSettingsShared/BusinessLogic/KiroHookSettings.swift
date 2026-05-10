import Foundation

nonisolated enum KiroHookSettings {
  fileprivate static let busy = AgentHookSettingsCommand.eventCommand(event: .busy, agent: .kiro)
  fileprivate static let idle = AgentHookSettingsCommand.eventCommand(event: .idle, agent: .kiro)
  fileprivate static let notify = AgentHookSettingsCommand.notificationCommand(agent: .kiro)
  fileprivate static let sessionStart = AgentHookSettingsCommand.eventCommand(
    event: .sessionStart, agent: .kiro)
  fileprivate static let defaultTimeoutMs = 10_000

  static func progressHooksByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: KiroProgressPayload(),
      invalidConfiguration: KiroHookSettingsError.invalidConfiguration
    )
  }

  static func notificationHooksByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: KiroNotificationPayload(),
      invalidConfiguration: KiroHookSettingsError.invalidConfiguration
    )
  }

  /// See `ClaudeHookSettings.allHooksByEvent` for the rationale.
  static func allHooksByEvent() throws -> [String: [JSONValue]] {
    var merged = try progressHooksByEvent()
    for (event, entries) in try notificationHooksByEvent() {
      merged[event, default: []].append(contentsOf: entries)
    }
    return merged
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
// `agentSpawn` is Kiro's session-start equivalent — it fires once when
// the agent is activated, so the badge appears as soon as the user
// opens a Kiro session. Kiro has no SessionEnd analogue, so the badge
// clears via the pid liveness sweep when the agent process exits.
private nonisolated struct KiroProgressPayload: Encodable {
  let hooks: [String: [KiroHookEntry]] = [
    "agentSpawn": [
      KiroHookEntry(command: KiroHookSettings.sessionStart, timeoutMs: 5_000)
    ],
    "userPromptSubmit": [
      KiroHookEntry(command: KiroHookSettings.busy, timeoutMs: KiroHookSettings.defaultTimeoutMs)
    ],
    "stop": [
      KiroHookEntry(command: KiroHookSettings.idle, timeoutMs: KiroHookSettings.defaultTimeoutMs)
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
