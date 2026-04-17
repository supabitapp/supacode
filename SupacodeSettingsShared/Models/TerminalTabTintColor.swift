import AppKit
import SwiftUI

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

  /// Resolved SwiftUI color for rendering.
  public var color: Color {
    switch self {
    case .green: .green
    case .orange: .orange
    case .red: .red
    case .blue: .blue
    case .purple: .purple
    case .yellow: .yellow
    case .teal: .teal
    }
  }

  /// Resolved AppKit color for use in NSImage tinting.
  public var nsColor: NSColor {
    switch self {
    case .green: .systemGreen
    case .orange: .systemOrange
    case .red: .systemRed
    case .blue: .systemBlue
    case .purple: .systemPurple
    case .yellow: .systemYellow
    case .teal: .systemTeal
    }
  }
}
