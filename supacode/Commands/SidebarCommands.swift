import Sharing
import SwiftUI

struct SidebarCommands: Commands {
  @FocusedValue(\.toggleLeftSidebarAction) private var toggleLeftSidebarAction
  @Shared(.settingsFile) private var settingsFile

  var body: some Commands {
    let toggleLeftSidebar = AppShortcuts.toggleLeftSidebar.effective(from: settingsFile.global)
    CommandGroup(replacing: .sidebar) {
      Button("Toggle Left Sidebar") {
        toggleLeftSidebarAction?()
      }
      .keyboardShortcut(
        toggleLeftSidebar.keyEquivalent, modifiers: toggleLeftSidebar.modifiers
      )
      .help("Toggle Left Sidebar (\(toggleLeftSidebar.display))")
      .disabled(toggleLeftSidebarAction == nil)
    }
  }
}

private struct ToggleLeftSidebarActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var toggleLeftSidebarAction: (() -> Void)? {
    get { self[ToggleLeftSidebarActionKey.self] }
    set { self[ToggleLeftSidebarActionKey.self] = newValue }
  }
}
