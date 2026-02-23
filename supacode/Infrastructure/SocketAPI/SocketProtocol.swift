import Foundation

nonisolated enum SocketErrorCode: String, Codable, Sendable {
  case invalidRequest = "invalid_request"
  case invalidParams = "invalid_params"
  case methodNotFound = "method_not_found"
  case worktreeNotFound = "worktree_not_found"
  case operationFailed = "operation_failed"
}

nonisolated enum SocketMethod: String, Codable, Sendable {
  case systemPing = "system.ping"
  case tabList = "tab.list"
  case tabCreate = "tab.create"
  case tabClose = "tab.close"
  case splitCreate = "split.create"
  case splitClose = "split.close"
}

nonisolated struct SocketRequest: Codable, Sendable, Equatable {
  let id: String?
  let method: String
  let params: [String: SocketValue]?

  var parsedMethod: SocketMethod? {
    SocketMethod(rawValue: method)
  }
}

nonisolated struct SocketResponse: Codable, Sendable, Equatable {
  let id: String?
  let isSuccess: Bool
  let result: SocketValue?
  let error: SocketErrorPayload?

  enum CodingKeys: String, CodingKey {
    case id
    case isSuccess = "ok"
    case result
    case error
  }

  static func success(id: String?, result: SocketValue = .object([:])) -> Self {
    Self(id: id, isSuccess: true, result: result, error: nil)
  }

  static func failure(id: String?, code: SocketErrorCode, message: String) -> Self {
    Self(
      id: id,
      isSuccess: false,
      result: nil,
      error: SocketErrorPayload(code: code.rawValue, message: message)
    )
  }
}

nonisolated struct SocketErrorPayload: Codable, Sendable, Equatable {
  let code: String
  let message: String
}

nonisolated enum SocketValue: Codable, Sendable, Equatable {
  case string(String)
  case int(Int)
  case bool(Bool)
  case null
  case array([SocketValue])
  case object([String: SocketValue])

  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  var arrayValue: [SocketValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  var objectValue: [String: SocketValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      self = .null
      return
    }

    if let value = try? container.decode(Bool.self) {
      self = .bool(value)
      return
    }

    if let value = try? container.decode(Int.self) {
      self = .int(value)
      return
    }

    if let value = try? container.decode(String.self) {
      self = .string(value)
      return
    }

    if let value = try? container.decode([SocketValue].self) {
      self = .array(value)
      return
    }

    if let value = try? container.decode([String: SocketValue].self) {
      self = .object(value)
      return
    }

    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "Unsupported JSON value"
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()

    switch self {
    case .string(let value):
      try container.encode(value)
    case .int(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}
