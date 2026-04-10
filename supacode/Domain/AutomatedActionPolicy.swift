/// Controls when automated actions (CLI commands, deeplinks) bypass
/// user confirmation.
enum AutomatedActionPolicy: String, Codable, Equatable, Sendable, CaseIterable {
  /// Always allow without confirmation.
  case always
  /// Allow only for CLI commands received via socket.
  case cliOnly
  /// Allow only for deeplinks received via URL scheme.
  case deeplinksOnly
  /// Always require confirmation.
  case never

  /// Human-readable label for the settings picker.
  var displayName: String {
    switch self {
    case .always: "Always"
    case .cliOnly: "CLI Only"
    case .deeplinksOnly: "Deeplinks Only"
    case .never: "Never"
    }
  }

  /// Whether the given source is allowed to bypass confirmation.
  func allowsBypass(from source: ActionSource) -> Bool {
    switch self {
    case .always: true
    case .cliOnly:
      switch source {
      case .socket: true
      case .urlScheme: false
      }
    case .deeplinksOnly:
      switch source {
      case .urlScheme: true
      case .socket: false
      }
    case .never: false
    }
  }
}
