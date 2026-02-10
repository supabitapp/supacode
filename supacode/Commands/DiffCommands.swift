import SwiftUI

struct DiffCommands: Commands {
  @FocusedValue(\.toggleDiffPanelAction) private var toggleDiffPanelAction

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      Button("Toggle Diff Panel") {
        toggleDiffPanelAction?()
      }
      .keyboardShortcut(
        AppShortcuts.toggleDiffPanel.keyEquivalent,
        modifiers: AppShortcuts.toggleDiffPanel.modifiers
      )
      .help("Toggle Diff Panel (\(AppShortcuts.toggleDiffPanel.display))")
      .disabled(toggleDiffPanelAction == nil)
    }
  }
}

private struct ToggleDiffPanelActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var toggleDiffPanelAction: (() -> Void)? {
    get { self[ToggleDiffPanelActionKey.self] }
    set { self[ToggleDiffPanelActionKey.self] = newValue }
  }
}
