import Foundation

public nonisolated
  enum JSONValue: Hashable, Sendable, Codable,
    ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([Self])
  case object([String: Self])

  // MARK: - Codable.

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([Self].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: Self].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  // MARK: - Expressible-by literals.

  public init(nilLiteral: ()) { self = .null }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(arrayLiteral elements: Self...) { self = .array(elements) }

  public init(dictionaryLiteral elements: (String, Self)...) {
    self = .object(.init(uniqueKeysWithValues: elements))
  }

  // MARK: - Accessors.

  public var arrayValue: [Self]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var objectValue: [String: Self]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  // MARK: - Encodable bridging.

  public init<T: Encodable>(_ value: T) throws {
    let data = try JSONEncoder().encode(EncodableBox(value))
    self = try JSONDecoder().decode(Self.self, from: data)
  }
}

private nonisolated struct EncodableBox<T: Encodable>: Encodable {
  let value: T
  init(_ value: T) { self.value = value }
  func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
