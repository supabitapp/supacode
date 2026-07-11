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

  /// True when any Supacode-managed Grok hook is missing the canonical env
  /// passthrough map. Grok hook subprocesses do not inherit terminal env, so a
  /// missing env map means presence badges silently no-op.
  ///
  /// Operates on an already-parsed settings root (same snapshot as the
  /// command-set check) so install-state never re-reads disk for this gate.
  static func managedHooksLackEnvPassthrough(in settingsObject: [String: JSONValue]) -> Bool {
    guard let hooksObject = settingsObject["hooks"]?.objectValue else { return false }
    let expected = AgentHookSettingsCommand.grokHookEnvPassthrough
    for (_, value) in hooksObject {
      guard let groups = value.arrayValue else { continue }
      for group in groups {
        guard let hooks = group.objectValue?["hooks"]?.arrayValue else { continue }
        for hook in hooks {
          guard
            let hookObject = hook.objectValue,
            let command = hookObject["command"]?.stringValue,
            AgentHookCommandOwnership.isSupacodeManagedCommand(command)
          else { continue }
          guard let envObject = hookObject["env"]?.objectValue else { return true }
          for (key, expectedValue) in expected {
            guard envObject[key]?.stringValue == expectedValue else { return true }
          }
        }
      }
    }
    return false
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
  private static let hookEnv = AgentHookSettingsCommand.grokHookEnvPassthrough

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
      .init(hooks: [.init(command: Self.sessionStart, timeout: 5, env: Self.hookEnv)])
    ],
    "UserPromptSubmit": [
      .init(hooks: [.init(command: Self.busy, timeout: 10, env: Self.hookEnv)])
    ],
    "PreToolUse": [
      .init(matcher: "", hooks: [.init(command: Self.busy, timeout: 5, env: Self.hookEnv)]),
      // Array-order: matched-by-name fires AFTER matcher-"", so awaiting wins.
      .init(
        matcher: Self.awaitingInputToolMatcher,
        hooks: [.init(command: Self.awaitingInput, timeout: 5, env: Self.hookEnv)]
      ),
    ],
    "PostToolUse": [
      .init(matcher: "", hooks: [.init(command: Self.idle, timeout: 5, env: Self.hookEnv)])
    ],
    "Notification": [
      .init(
        matcher: "",
        hooks: [.init(command: Self.awaitingInputAndNotify, timeout: 10, env: Self.hookEnv)]
      )
    ],
    "Stop": [
      .init(hooks: [.init(command: Self.idleAndNotify, timeout: 10, env: Self.hookEnv)])
    ],
    "SessionEnd": [
      .init(matcher: "", hooks: [.init(command: Self.sessionEndAndIdle, timeout: 5, env: Self.hookEnv)])
    ],
  ]
}
