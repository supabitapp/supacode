import SwiftUI

enum TerminalTabBarColors {
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

struct SurfaceChromeAppearance: Equatable {
  // Use this for chrome math (overlay tint, separator opacity, the bar's
  // `\.colorScheme` override). Derived from the terminal background's
  // luminance, NOT the system appearance.
  var colorScheme: ColorScheme
  // Use this only when escaping the chrome override (popovers, context
  // menus). Mirrors the system's effective `\.colorScheme`.
  var systemColorScheme: ColorScheme

  // Plain .white/.black so the opacity math stays exact; Color.primary
  // resolves with its own alpha and would silently shift overlays.
  var overlayTint: Color {
    colorScheme == .dark ? .white : .black
  }

  var separatorOpacity: Double {
    colorScheme == .dark ? 0.22 : 0.14
  }
}

private struct SurfaceChromeAppearanceKey: EnvironmentKey {
  static let defaultValue = SurfaceChromeAppearance(
    colorScheme: .dark,
    systemColorScheme: .dark
  )
}

extension EnvironmentValues {
  var surfaceChromeAppearance: SurfaceChromeAppearance {
    get { self[SurfaceChromeAppearanceKey.self] }
    set { self[SurfaceChromeAppearanceKey.self] = newValue }
  }
}

extension View {
  // Re-injects the system `\.colorScheme` for chrome subtrees that escape the
  // window-tint override (popovers, context menus, sheets, the inline rename
  // field, command palette).
  func inheritSystemColorScheme() -> some View {
    modifier(TerminalChromeEscape())
  }
}

struct TerminalChromeEscape: ViewModifier {
  @Environment(\.surfaceChromeAppearance)
  private var chromeAppearance

  func body(content: Content) -> some View {
    content.environment(\.colorScheme, chromeAppearance.systemColorScheme)
  }
}
