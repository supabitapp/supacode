import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

// MARK: - Selection → settings window bridge.

/// Observes `store.settings.selection` and opens the dedicated settings window when it becomes non-nil.
/// Applied to the main window content so the environment action is always available.
private struct OpenSettingsOnSelection: ViewModifier {
  @Environment(\.openWindow) private var openWindow
  let store: StoreOf<AppFeature>

  func body(content: Content) -> some View {
    content
      .onChange(of: store.settings.selection) { _, new in
        guard new != nil else { return }
        openWindow(id: WindowID.settings)
      }
  }
}

extension View {
  func openSettingsOnSelection(store: StoreOf<AppFeature>) -> some View {
    modifier(OpenSettingsOnSelection(store: store))
  }
}

// MARK: - Menu button.

/// Settings menu button that opens the dedicated settings window and supports custom keyboard shortcuts.
struct SettingsMenuButton: View {
  @Environment(\.openWindow) private var openWindow
  let shortcutOverrides: [AppShortcutID: AppShortcutOverride]
  let onOpen: () -> Void

  var body: some View {
    let settings = AppShortcuts.openSettings.effective(from: shortcutOverrides)
    Button("Settings...", systemImage: "gear") {
      onOpen()
      openWindow(id: WindowID.settings)
    }
    .appKeyboardShortcut(settings)
  }
}
