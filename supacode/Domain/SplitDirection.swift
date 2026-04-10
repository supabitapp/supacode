/// Direction for terminal surface splits.
/// Keep in sync with `CLISplitDirection` in `supacode-cli/Helpers/CLISplitDirection.swift`.
enum SplitDirection: Equatable, Sendable {
  case horizontal
  case vertical

  nonisolated init?(rawValue: String) {
    switch rawValue {
    case "horizontal", "h": self = .horizontal
    case "vertical", "v": self = .vertical
    default: return nil
    }
  }

  var rawValue: String {
    switch self {
    case .horizontal: "horizontal"
    case .vertical: "vertical"
    }
  }
}

// Explicit Codable using raw strings to preserve backward compatibility
// with the previous `String`-backed enum encoding.
extension SplitDirection: Codable {
  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let direction = SplitDirection(rawValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid SplitDirection: \(value)")
    }
    self = direction
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
