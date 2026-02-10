import SwiftUI

struct SidebarCommands: Commands {
  @FocusedValue(\.toggleLeftSidebarAction) private var toggleLeftSidebarAction
  @FocusedValue(\.toggleChangesPanelAction) private var toggleChangesPanelAction

  var body: some Commands {
    CommandGroup(replacing: .sidebar) {
      Button("Toggle Left Sidebar") {
        toggleLeftSidebarAction?()
      }
      .keyboardShortcut(
        AppShortcuts.toggleLeftSidebar.keyEquivalent, modifiers: AppShortcuts.toggleLeftSidebar.modifiers
      )
      .help("Toggle Left Sidebar (\(AppShortcuts.toggleLeftSidebar.display))")
      .disabled(toggleLeftSidebarAction == nil)

      Button("Toggle Changes") {
        toggleChangesPanelAction?()
      }
      .keyboardShortcut(
        AppShortcuts.toggleChanges.keyEquivalent,
        modifiers: AppShortcuts.toggleChanges.modifiers
      )
      .help("Toggle Changes (\(AppShortcuts.toggleChanges.display))")
      .disabled(toggleChangesPanelAction == nil)
    }
  }
}

private struct ToggleLeftSidebarActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct ToggleChangesPanelActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var toggleLeftSidebarAction: (() -> Void)? {
    get { self[ToggleLeftSidebarActionKey.self] }
    set { self[ToggleLeftSidebarActionKey.self] = newValue }
  }

  var toggleChangesPanelAction: (() -> Void)? {
    get { self[ToggleChangesPanelActionKey.self] }
    set { self[ToggleChangesPanelActionKey.self] = newValue }
  }
}
