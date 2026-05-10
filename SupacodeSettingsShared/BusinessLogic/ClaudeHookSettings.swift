import Foundation

nonisolated enum ClaudeHookSettings {
  fileprivate static let busyOn = AgentHookSettingsCommand.busyCommand(active: true)
  fileprivate static let busyOff = AgentHookSettingsCommand.busyCommand(active: false)
  fileprivate static let notify = AgentHookSettingsCommand.notificationCommand(agent: "claude")
  fileprivate static let sessionStart = AgentHookSettingsCommand.sessionEventCommand(
    event: "session_start", agent: "claude")
  fileprivate static let sessionEnd = AgentHookSettingsCommand.sessionEventCommand(
    event: "session_end", agent: "claude")

  static func progressHookGroupsByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: ClaudeProgressPayload(),
      invalidConfiguration: ClaudeHookSettingsError.invalidConfiguration
    )
  }

  static func notificationHookGroupsByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: ClaudeNotificationPayload(),
      invalidConfiguration: ClaudeHookSettingsError.invalidConfiguration
    )
  }

  /// Progress + notification merged into a single hook map. Used so install
  /// runs once per agent (covering all events the integration touches), so
  /// the file installer's prune step removes every Supacode-managed command
  /// in those events — including stale variants from older Supacode versions.
  static func allHookGroupsByEvent() throws -> [String: [JSONValue]] {
    try mergeHookGroups(
      progressHookGroupsByEvent(),
      notificationHookGroupsByEvent()
    )
  }
}

private nonisolated func mergeHookGroups(
  _ first: [String: [JSONValue]], _ second: [String: [JSONValue]]
) -> [String: [JSONValue]] {
  var merged = first
  for (event, groups) in second {
    merged[event, default: []].append(contentsOf: groups)
  }
  return merged
}

nonisolated enum ClaudeHookSettingsError: Error {
  case invalidConfiguration
}

// MARK: - Progress hooks.

// UserPromptSubmit sets busy, Stop/SessionEnd/PostToolUseFailure clears it.
// SessionStart/SessionEnd also report agent presence so the sidebar/tab badge
// can light up while Claude is running in this surface.
private nonisolated struct ClaudeProgressPayload: Encodable {
  let hooks: [String: [AgentHookGroup]] = [
    "SessionStart": [
      .init(hooks: [.init(command: ClaudeHookSettings.sessionStart, timeout: 5)])
    ],
    "UserPromptSubmit": [
      .init(hooks: [
        .init(command: ClaudeHookSettings.busyOn, timeout: 10)
      ])
    ],
    "Stop": [
      .init(hooks: [.init(command: ClaudeHookSettings.busyOff, timeout: 10)])
    ],
    "PostToolUseFailure": [
      .init(hooks: [.init(command: ClaudeHookSettings.busyOff, timeout: 5)])
    ],
    "SessionEnd": [
      .init(
        matcher: "",
        hooks: [
          .init(command: ClaudeHookSettings.sessionEnd, timeout: 5),
          .init(command: ClaudeHookSettings.busyOff, timeout: 1),
        ]
      )
    ],
  ]
}

// MARK: - Notification hooks.

// Stop forwards lastAssistantMessage, Notification forwards message/title.
private nonisolated struct ClaudeNotificationPayload: Encodable {
  let hooks: [String: [AgentHookGroup]] = [
    "Stop": [
      .init(hooks: [.init(command: ClaudeHookSettings.notify, timeout: 10)])
    ],
    "Notification": [
      .init(matcher: "", hooks: [.init(command: ClaudeHookSettings.notify, timeout: 10)])
    ],
  ]
}
