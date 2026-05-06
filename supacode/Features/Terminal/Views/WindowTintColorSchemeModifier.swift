import SwiftUI

extension View {
  // Override `\.colorScheme` to match the terminal background's luminance so
  // text/icons painted over the window tint (loading view, multi-select,
  // empty states) stay readable when the user's system appearance differs
  // from the Ghostty theme — e.g. light system + dark terminal background.
  func windowTintColorScheme(manager: WorktreeTerminalManager) -> some View {
    modifier(WindowTintColorScheme(manager: manager))
  }
}

private struct WindowTintColorScheme: ViewModifier {
  let manager: WorktreeTerminalManager
  // Captured here, BEFORE the override below replaces `\.colorScheme`. Anything
  // that reads `@Environment(\.colorScheme)` underneath the override would
  // otherwise see the overridden value and `inheritSystemColorScheme()` would
  // be a no-op.
  @Environment(\.colorScheme) private var systemColorScheme
  @State private var configReloadCounter = 0

  func body(content: Content) -> some View {
    // Force-track these dependencies so SwiftUI re-evaluates body and re-resolves
    // `surfaceBackgroundColorScheme()` (an opaque AppKit read) on system Light/Dark
    // flips and on Ghostty config reloads.
    _ = configReloadCounter
    _ = systemColorScheme
    let tintScheme = manager.surfaceBackgroundColorScheme()
    let appearance = SurfaceChromeAppearance(
      colorScheme: tintScheme,
      systemColorScheme: systemColorScheme
    )
    return content
      .environment(\.surfaceChromeAppearance, appearance)
      .environment(\.colorScheme, tintScheme)
      .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigDidChange)) { _ in
        configReloadCounter &+= 1
      }
  }
}
