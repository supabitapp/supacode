import SupacodeSettingsShared

/// Direction for terminal surface splits.
/// Keep in sync with `CLISplitDirection` in `supacode-cli/Helpers/CLISplitDirection.swift`.
nonisolated enum SplitDirection: Equatable, Sendable {
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

  /// Parses the four-way direction a `pane focus` / `tab move` deeplink carries.
  nonisolated init?(deeplinkValue: String) {
    switch deeplinkValue {
    case "right", "r": self = .right
    case "left", "l": self = .left
    case "down", "d": self = .down
    case "up", "u": self = .up
    default: return nil
    }
  }

  /// The split-tree insertion direction for this menu direction.
  var newSplitDirection: SplitTree<PaneID>.NewDirection {
    switch self {
    case .right: .right
    case .left: .left
    case .down: .down
    case .up: .top
    }
  }

  /// The spatial focus direction for this menu direction.
  var focusSplitDirection: SplitTree<PaneID>.FocusDirection {
    switch self {
    case .right: .spatial(.right)
    case .left: .spatial(.left)
    case .down: .spatial(.down)
    case .up: .spatial(.top)
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

  /// The app-owned layout shortcut for this split direction.
  var appShortcut: AppShortcut {
    switch self {
    case .right: AppShortcuts.splitRight
    case .left: AppShortcuts.splitLeft
    case .down: AppShortcuts.splitDown
    case .up: AppShortcuts.splitUp
    }
  }

  /// The app-owned layout shortcut for focusing the neighbor in this direction.
  var focusAppShortcut: AppShortcut {
    switch self {
    case .right: AppShortcuts.focusSplitRight
    case .left: AppShortcuts.focusSplitLeft
    case .down: AppShortcuts.focusSplitDown
    case .up: AppShortcuts.focusSplitUp
    }
  }

  var focusMenuBarTitle: String {
    switch self {
    case .right: "Focus Split Right"
    case .left: "Focus Split Left"
    case .down: "Focus Split Down"
    case .up: "Focus Split Up"
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
nonisolated extension SplitDirection: Codable {
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
