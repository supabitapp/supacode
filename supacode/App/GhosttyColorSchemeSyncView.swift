import AppKit
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// Synchronizes the user's appearance mode preference with both NSApp appearance
/// and Ghostty's color scheme, and reloads Ghostty config when terminal theme sync is toggled.
struct GhosttyColorSchemeSyncView<Content: View>: View {
  @Shared(.settingsFile) private var settingsFile
  let ghostty: GhosttyRuntime
  let content: Content
  // The main window pins `window.appearance` to the terminal background, so an
  // environment `\.colorScheme` read here would echo the terminal back into
  // `setColorScheme` (OSC 11 dark would flip a light/dark theme to its dark
  // variant). Observe the app-level appearance instead: it tracks the system
  // when `NSApp.appearance` is nil and is untouched by the window pin.
  @State private var systemColorScheme = Self.appColorScheme()
  @State private var appearanceObservation: NSKeyValueObservation?

  init(ghostty: GhosttyRuntime, @ViewBuilder content: () -> Content) {
    self.ghostty = ghostty
    self.content = content()
  }

  var body: some View {
    let resolved = settingsFile.global.appearanceMode.resolved(systemColorScheme: systemColorScheme)
    content
      .task {
        applyAppAppearance()
        ghostty.setColorScheme(resolved)
      }
      .onAppear {
        // NSApplication.effectiveAppearance is KVO-compliant and fires on main.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
          MainActor.assumeIsolated {
            systemColorScheme = Self.appColorScheme()
          }
        }
      }
      .onChange(of: settingsFile.global.appearanceMode) {
        applyAppAppearance()
      }
      .onChange(of: resolved) { _, newValue in
        ghostty.setColorScheme(newValue)
      }
      .onChange(of: settingsFile.global.terminalThemeSyncEnabled) {
        ghostty.reloadAppConfig()
      }
  }

  private static func appColorScheme() -> ColorScheme {
    NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
  }

  private func applyAppAppearance() {
    let appearance: NSAppearance? =
      switch settingsFile.global.appearanceMode {
      case .system: nil
      case .light: NSAppearance(named: .aqua)
      case .dark: NSAppearance(named: .darkAqua)
      }
    // Set only the app appearance: auxiliary windows (nil appearance) inherit it,
    // while the terminal window owns its own appearance (driven by the focused
    // surface via WindowChromeApplier). Looping every window here would clobber
    // that terminal-driven value and fight it nondeterministically.
    NSApp.appearance = appearance
  }
}
