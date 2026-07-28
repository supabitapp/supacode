import Foundation

/// Size of the app chrome's text: the sidebar, tab bar, toolbars, and Settings.
/// A fixed set of sizes rather than a free-form scale, so the layout only has to
/// hold at three known points.
///
/// The size is applied by resolving each semantic font explicitly (see
/// `View.appFont`), because macOS SwiftUI does not resize text in response to
/// `dynamicTypeSize`. The Ghostty terminal surface is NSView-backed with its own
/// font system and is unaffected.
public nonisolated enum ChromeTextSize: String, CaseIterable, Codable, Identifiable, Sendable {
  case standard
  case large
  case extraLarge

  public static let `default` = ChromeTextSize.standard

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .standard: "Default"
    case .large: "Large"
    case .extraLarge: "Extra Large"
    }
  }

  /// Multiplier applied to each semantic font's system point size. macOS has no
  /// Dynamic Type step table to inherit, so the two steps are chosen to land
  /// near where iOS's `.xLarge` and `.xxLarge` sit.
  public var scale: Double {
    switch self {
    case .standard: 1.0
    case .large: 1.15
    case .extraLarge: 1.3
    }
  }
}
