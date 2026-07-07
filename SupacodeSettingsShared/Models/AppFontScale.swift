import SwiftUI

/// User-facing scale for the app's SwiftUI chrome — sidebar, tab bar, toolbars,
/// command palette, settings — on high-density displays where the default
/// interface text is uncomfortably small.
///
/// Deliberately distinct from the Ghostty terminal font size, which each
/// surface owns and the user drives with ⌘+/−. This scale never touches the
/// terminal: the surface is an AppKit `NSView`, so it ignores the SwiftUI
/// `\.dynamicTypeSize` this maps to and keeps its own point size.
///
/// Backed by `DynamicTypeSize` rather than a raw multiplier so it composes with
/// the app's Dynamic Type–based fonts instead of fighting hardcoded point
/// sizes. `.standard` maps to `.large`, macOS's default content size, so it is
/// a visual no-op.
public enum AppFontScale: String, CaseIterable, Identifiable, Codable, Sendable {
  case small
  case standard
  case large
  case extraLarge
  case huge

  /// The system default: no change to the app's baseline chrome size.
  public static let `default` = AppFontScale.standard

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .small: "Small"
    case .standard: "Default"
    case .large: "Large"
    case .extraLarge: "Extra Large"
    case .huge: "Huge"
    }
  }

  public var dynamicTypeSize: DynamicTypeSize {
    switch self {
    case .small: .small
    case .standard: .large
    case .large: .xLarge
    case .extraLarge: .xxLarge
    case .huge: .xxxLarge
    }
  }
}
