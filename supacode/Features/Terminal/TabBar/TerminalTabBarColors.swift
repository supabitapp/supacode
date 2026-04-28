import AppKit
import SwiftUI

enum TerminalTabBarColors {
  static var inactiveTabBackground: Color {
    .clear
  }

  static var activeText: Color {
    .primary
  }

  static var inactiveText: Color {
    .secondary
  }

  static var dropIndicator: Color {
    Color.accentColor
  }
}

private struct SurfaceChromeBackgroundColorKey: EnvironmentKey {
  static let defaultValue = Color(nsColor: .windowBackgroundColor)
}

private struct SurfaceChromeColorSchemeKey: EnvironmentKey {
  static let defaultValue = ColorScheme.dark
}

extension EnvironmentValues {
  var surfaceChromeBackgroundColor: Color {
    get { self[SurfaceChromeBackgroundColorKey.self] }
    set { self[SurfaceChromeBackgroundColorKey.self] = newValue }
  }

  var surfaceChromeColorScheme: ColorScheme {
    get { self[SurfaceChromeColorSchemeKey.self] }
    set { self[SurfaceChromeColorSchemeKey.self] = newValue }
  }
}
