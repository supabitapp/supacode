/// Color token for terminal tab tint indicators, used in place of
/// `Color` so that related types can remain `Equatable` and `Sendable`.
public enum TerminalTabTintColor: String, Codable, CaseIterable, Hashable, Sendable {
  case green
  case orange
  case red
  case blue
  case purple
  case yellow
  case teal
}
