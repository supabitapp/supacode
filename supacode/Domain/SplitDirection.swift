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

/// Four-direction split selector used by File menu commands and the tab-bar split menu.
/// Single source of truth for the binding string, SF Symbol, and user-facing labels.
enum TerminalSplitMenuDirection: Equatable, Sendable, CaseIterable {
  case right
  case left
  case down
  case up

  var ghosttyBinding: String {
    switch self {
    case .right: "new_split:right"
    case .left: "new_split:left"
    case .down: "new_split:down"
    case .up: "new_split:up"
    }
  }

  var systemImage: String {
    switch self {
    case .right: "rectangle.righthalf.inset.filled"
    case .left: "rectangle.leadinghalf.inset.filled"
    case .down: "rectangle.bottomhalf.inset.filled"
    case .up: "rectangle.tophalf.inset.filled"
    }
  }

  /// Short title for the tab bar (context makes "Terminal" obvious).
  var title: String {
    switch self {
    case .right: "Split Right"
    case .left: "Split Left"
    case .down: "Split Down"
    case .up: "Split Up"
    }
  }

  /// Long title for the File menu (sits alongside "New Terminal Tab" / "Close Terminal").
  var menuBarTitle: String {
    switch self {
    case .right: "Split Terminal Right"
    case .left: "Split Terminal Left"
    case .down: "Split Terminal Down"
    case .up: "Split Terminal Up"
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
