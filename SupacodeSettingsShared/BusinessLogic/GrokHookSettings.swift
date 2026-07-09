import Foundation

nonisolated enum GrokHookSettings {
  /// Canonical hook map for Grok. One composite command per (event,
  /// matcher) slot keeps the prune-and-replace cycle idempotent.
  static func hooksByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: GrokHooksPayload(),
      invalidConfiguration: GrokHookSettingsError.invalidConfiguration
    )
  }
}

nonisolated enum GrokHookSettingsError: Error {
  case invalidConfiguration
}

// MARK: - Hook payload.

// Grok loads `~/.grok/hooks/*.json` and accepts Claude-compatible PascalCase
// event names, so the busy/idle/awaitingInput mapping mirrors
// `ClaudeHooksPayload`. The `AskUserQuestion|ExitPlanMode` matcher is
// reused from Claude and assumed inert on Grok today; revisit if Grok adds
// matching tool names.
private nonisolated struct GrokHooksPayload: Encodable {
  static let awaitingInputToolMatcher = "AskUserQuestion|ExitPlanMode"

  private static let busy = AgentHookSettingsCommand.compositeCommand(
    events: [.busy], forwardStdinAsNotification: false, agent: .grok, )
  private static let idle = AgentHookSettingsCommand.compositeCommand(
    events: [.idle], forwardStdinAsNotification: false, agent: .grok, )
  private static let awaitingInputAndNotify = AgentHookSettingsCommand.compositeCommand(
    events: [.awaitingInput], forwardStdinAsNotification: true, agent: .grok, )
  private static let awaitingInput = AgentHookSettingsCommand.compositeCommand(
    events: [.awaitingInput], forwardStdinAsNotification: false, agent: .grok, )
  private static let idleAndNotify = AgentHookSettingsCommand.compositeCommand(
    events: [.idle], forwardStdinAsNotification: true, agent: .grok, )
  private static let sessionStart = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionStart], forwardStdinAsNotification: false, agent: .grok, )
  private static let sessionEndAndIdle = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionEnd, .idle], forwardStdinAsNotification: false, agent: .grok, )

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
    "Stop": [
      .init(hooks: [.init(command: Self.idleAndNotify, timeout: 10)])
    ],
    "SessionEnd": [
      .init(matcher: "", hooks: [.init(command: Self.sessionEndAndIdle, timeout: 5)])
    ],
  ]
}
