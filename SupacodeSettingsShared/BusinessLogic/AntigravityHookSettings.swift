import Foundation

nonisolated enum AntigravityHookSettings {
  private struct EventSpec: Equatable, Sendable {
    let name: String
    let command: String
    let timeout: Int

    init(name: String, command: String, timeout: Int) {
      assert(!name.isEmpty, "Antigravity hook event name must not be empty.")
      assert(!command.isEmpty, "Antigravity hook command must not be empty.")
      assert(timeout > 0, "Antigravity hook timeout must be positive.")
      self.name = name
      self.command = command
      self.timeout = timeout
    }
  }

  static func hooksByEvent() -> [String: [JSONValue]] {
    let sessionStart = AgentHookSettingsCommand.compositeCommand(
      events: [.sessionStart], forwardStdinAsNotification: false, agent: .antigravity)
    let busy = AgentHookSettingsCommand.compositeCommand(
      events: [.busy], forwardStdinAsNotification: false, agent: .antigravity)
    let idle = AgentHookSettingsCommand.compositeCommand(
      events: [.idle], forwardStdinAsNotification: false, agent: .antigravity)
    let stop = AgentHookSettingsCommand.claudeStopCommand(agent: .antigravity)

    let events: [EventSpec] = [
      .init(name: "SessionStart", command: sessionStart, timeout: 5),
      .init(name: "PreInvocation", command: busy, timeout: 5),
      .init(name: "PreToolUse", command: busy, timeout: 5),
      .init(name: "PostInvocation", command: idle, timeout: 5),
      .init(name: "PostToolUse", command: idle, timeout: 5),
      .init(name: "Stop", command: stop, timeout: 10),
    ]

    var result: [String: [JSONValue]] = [:]
    for spec in events {
      let hook: [String: JSONValue] = [
        "type": .string("command"),
        "command": .string(spec.command),
        "prompt": .string(""),
        "timeout": .int(spec.timeout),
      ]
      result[spec.name] = [.object(hook)]
    }
    return result
  }
}
