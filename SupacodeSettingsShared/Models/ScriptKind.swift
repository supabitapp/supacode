import Foundation

/// Identifies the semantic category of a user-defined script.
/// Predefined kinds carry default icon, color, and name; `.custom`
/// requires explicit values stored on the owning `ScriptDefinition`.
public enum ScriptKind: String, Codable, CaseIterable, Hashable, Sendable {
  case run
  case debug
  case test
  case deploy
  case lint
  case format
  case custom

  /// Default display name shown in UI when the user hasn't provided one.
  public nonisolated var defaultName: String {
    switch self {
    case .run: "Run"
    case .debug: "Debug"
    case .test: "Test"
    case .deploy: "Deploy"
    case .lint: "Lint"
    case .format: "Format"
    case .custom: "Custom"
    }
  }

  /// Default SF Symbol name for the script kind.
  public nonisolated var defaultSystemImage: String {
    switch self {
    case .run: "play.fill"
    case .debug: "ant.fill"
    case .test: "checkmark.diamond.fill"
    case .deploy: "arrow.up.circle.fill"
    case .lint: "exclamationmark.triangle.fill"
    case .format: "text.alignleft"
    case .custom: "terminal.fill"
    }
  }

  /// Default tab tint color for the script kind.
  public nonisolated var defaultTintColor: TerminalTabTintColor {
    switch self {
    case .run: .green
    case .debug: .orange
    case .test: .blue
    case .deploy: .purple
    case .lint: .yellow
    case .format: .teal
    case .custom: .teal
    }
  }
}
