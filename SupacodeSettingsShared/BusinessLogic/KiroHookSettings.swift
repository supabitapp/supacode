import Foundation

nonisolated enum KiroHookSettings {
  fileprivate static let defaultTimeoutMs = 10_000

  /// Single canonical hook map for Kiro. See `ClaudeHookSettings` for the
  /// composite-command rationale (one Supacode-managed entry per slot →
  /// idempotent prune-and-replace).
  static func hooksByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: KiroHooksPayload(),
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

// MARK: - Hook payload.

// Kiro uses camelCase event names ("userPromptSubmit", "stop") unlike
// Claude/Codex which use PascalCase ("UserPromptSubmit", "Stop").
// `agentSpawn` is Kiro's session-start equivalent — it fires once when
// the agent is activated, so the badge appears as soon as the user
// opens a Kiro session. Kiro has no SessionEnd analogue, so the badge
// clears via the pid liveness sweep when the agent process exits.
private nonisolated struct KiroHooksPayload: Encodable {
  private static let busy = AgentHookSettingsCommand.compositeCommand(
    events: [.busy], forwardStdinAsNotification: false, agent: .kiro)
  private static let idleAndNotify = AgentHookSettingsCommand.compositeCommand(
    events: [.idle], forwardStdinAsNotification: true, agent: .kiro)
  private static let sessionStart = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionStart], forwardStdinAsNotification: false, agent: .kiro)

  let hooks: [String: [KiroHookEntry]] = [
    "agentSpawn": [
      KiroHookEntry(command: Self.sessionStart, timeoutMs: 5_000)
    ],
    "userPromptSubmit": [
      KiroHookEntry(command: Self.busy, timeoutMs: KiroHookSettings.defaultTimeoutMs)
    ],
    "stop": [
      KiroHookEntry(command: Self.idleAndNotify, timeoutMs: KiroHookSettings.defaultTimeoutMs)
    ],
  ]
}
