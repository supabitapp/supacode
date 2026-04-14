import Foundation

nonisolated enum KiroHookSettings {
  fileprivate static let busyOn = AgentHookSettingsCommand.busyCommand(active: true)
  fileprivate static let busyOff = AgentHookSettingsCommand.busyCommand(active: false)
  fileprivate static let notify = AgentHookSettingsCommand.notificationCommand(agent: "kiro")

  static func progressHookEntriesByEvent() throws -> [String: [JSONValue]] {
    try KiroHookPayloadSupport.extractHookEntries(
      from: KiroProgressPayload(),
      invalidConfiguration: KiroHookSettingsError.invalidConfiguration
    )
  }

  static func notificationHookEntriesByEvent() throws -> [String: [JSONValue]] {
    try KiroHookPayloadSupport.extractHookEntries(
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
  // swiftlint:disable:next identifier_name
  let timeout_ms: Int

  init(command: String, timeoutMs: Int) {
    self.command = command
    self.timeout_ms = timeoutMs
  }
}

// MARK: - Progress hooks.

private nonisolated struct KiroProgressPayload: Encodable {
  let hooks: [String: [KiroHookEntry]] = [
    "userPromptSubmit": [
      KiroHookEntry(command: KiroHookSettings.busyOn, timeoutMs: 10_000),
    ],
    "stop": [
      KiroHookEntry(command: KiroHookSettings.busyOff, timeoutMs: 10_000),
    ],
  ]
}

// MARK: - Notification hooks.

private nonisolated struct KiroNotificationPayload: Encodable {
  let hooks: [String: [KiroHookEntry]] = [
    "stop": [
      KiroHookEntry(command: KiroHookSettings.notify, timeoutMs: 10_000),
    ],
  ]
}

// MARK: - Payload support for flat format.

nonisolated enum KiroHookPayloadSupport {
  static func extractHookEntries<T: Encodable>(
    from payload: T,
    invalidConfiguration: @autoclosure () -> Error
  ) throws -> [String: [JSONValue]] {
    guard
      let objectValue = try JSONValue(payload).objectValue,
      let hooksValue = objectValue["hooks"]?.objectValue
    else {
      throw invalidConfiguration()
    }
    var result: [String: [JSONValue]] = [:]
    for (event, value) in hooksValue {
      guard let entries = value.arrayValue else {
        throw invalidConfiguration()
      }
      result[event] = entries
    }
    return result
  }
}
