import Foundation

nonisolated enum ClaudeHookSettings {
  fileprivate static let busy = AgentHookSettingsCommand.eventCommand(event: .busy, agent: .claude)
  fileprivate static let idle = AgentHookSettingsCommand.eventCommand(event: .idle, agent: .claude)
  fileprivate static let awaitingInput = AgentHookSettingsCommand.eventCommand(
    event: .awaitingInput, agent: .claude)
  fileprivate static let notify = AgentHookSettingsCommand.notificationCommand(agent: .claude)
  fileprivate static let sessionStart = AgentHookSettingsCommand.eventCommand(
    event: .sessionStart, agent: .claude)
  fileprivate static let sessionEnd = AgentHookSettingsCommand.eventCommand(
    event: .sessionEnd, agent: .claude)

  static func progressHooksByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: ClaudeProgressPayload(),
      invalidConfiguration: ClaudeHookSettingsError.invalidConfiguration
    )
  }

  static func notificationHooksByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: ClaudeNotificationPayload(),
      invalidConfiguration: ClaudeHookSettingsError.invalidConfiguration
    )
  }

  /// Progress + notification merged into a single hook map. Used so install
  /// runs once per agent (covering all events the integration touches), so
  /// the file installer's prune step removes every Supacode-managed command
  /// in those events — including stale variants from older Supacode versions.
  static func allHooksByEvent() throws -> [String: [JSONValue]] {
    var merged = try progressHooksByEvent()
    for (event, groups) in try notificationHooksByEvent() {
      merged[event, default: []].append(contentsOf: groups)
    }
    return merged
  }
}

nonisolated enum ClaudeHookSettingsError: Error {
  case invalidConfiguration
}

// MARK: - Progress hooks.

// Atomic state-set: every Pre/PostToolUse fires `busy`, repeated firings
// are idempotent. AskUserQuestion / ExitPlanMode / Notification overwrite
// to `awaitingInput`; the next PostToolUse / PreToolUse / Stop overwrites
// back to `busy` or `idle`. Stop and SessionEnd are the turn-boundary
// reset; pid liveness sweep is the safety net for crashed turns.
private nonisolated struct ClaudeProgressPayload: Encodable {
  static let awaitingInputToolMatcher = "AskUserQuestion|ExitPlanMode"
  let hooks: [String: [AgentHookGroup]] = [
    "SessionStart": [
      .init(hooks: [.init(command: ClaudeHookSettings.sessionStart, timeout: 5)])
    ],
    "UserPromptSubmit": [
      .init(hooks: [.init(command: ClaudeHookSettings.busy, timeout: 10)])
    ],
    "PreToolUse": [
      .init(matcher: "", hooks: [.init(command: ClaudeHookSettings.busy, timeout: 5)]),
      // Array-order: matched-by-name fires AFTER matcher-"", so awaiting wins.
      .init(
        matcher: ClaudeProgressPayload.awaitingInputToolMatcher,
        hooks: [.init(command: ClaudeHookSettings.awaitingInput, timeout: 5)]
      ),
    ],
    "PostToolUse": [
      .init(matcher: "", hooks: [.init(command: ClaudeHookSettings.busy, timeout: 5)])
    ],
    "Notification": [
      .init(matcher: "", hooks: [.init(command: ClaudeHookSettings.awaitingInput, timeout: 5)])
    ],
    "Stop": [
      .init(hooks: [.init(command: ClaudeHookSettings.idle, timeout: 5)])
    ],
    "SessionEnd": [
      .init(
        matcher: "",
        hooks: [
          .init(command: ClaudeHookSettings.sessionEnd, timeout: 5),
          .init(command: ClaudeHookSettings.idle, timeout: 1),
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
