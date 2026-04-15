import Foundation

nonisolated enum AgentHookPayloadSupport {
  static func extractHookGroups<T: Encodable>(
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
      guard let groups = value.arrayValue else {
        throw invalidConfiguration()
      }
      result[event] = groups
    }
    return result
  }
}

nonisolated struct AgentHookGroup: Encodable {
  let matcher: String?
  let hooks: [AgentCommandHook]

  init(matcher: String? = nil, hooks: [AgentCommandHook]) {
    self.matcher = matcher
    self.hooks = hooks
  }
}

nonisolated struct AgentCommandHook: Encodable {
  let type = "command"
  let command: String
  let timeout: Int

  init(command: String, timeout: Int) {
    self.command = command
    self.timeout = timeout
  }
}
