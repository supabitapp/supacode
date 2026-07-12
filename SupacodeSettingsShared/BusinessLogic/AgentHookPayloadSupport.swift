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
  let env: [String: String]?

  init(command: String, timeout: Int, env: [String: String]? = nil) {
    self.command = command
    self.timeout = timeout
    self.env = env
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, forKey: .type)
    try container.encode(command, forKey: .command)
    try container.encode(timeout, forKey: .timeout)
    if let env, !env.isEmpty {
      try container.encode(env, forKey: .env)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case type, command, timeout, env
  }
}
