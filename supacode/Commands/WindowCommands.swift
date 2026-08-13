import Sharing
import SupacodeSettingsShared
import SwiftUI

struct WindowCommands: Commands {
  @Shared(.settingsFile) private var settingsFile
  @FocusedValue(\.closeTabAction) private var closeTabAction
  @FocusedValue(\.terminateAllTerminalSessionsAction) private var terminateAllTerminalSessionsAction

  var body: some Commands {
    // Close Tab is non-customizable, so it always resolves and always owns ⌘W.
    let closeTab = AppShortcuts.closeTab.effective(from: settingsFile.global.shortcutOverrides)
    let closeTabEnabled = closeTabAction?.isEnabled == true
    CommandGroup(replacing: .saveItem) {
      Button("Close Tab", systemImage: "xmark") {
        closeTabAction?()
      }
      // Suppressed while unavailable so Close Window can claim ⌘W.
      .appKeyboardShortcut(closeTabEnabled ? closeTab : nil)
      .disabled(!closeTabEnabled)

      Button("Terminate All Terminal Sessions…") {
        terminateAllTerminalSessionsAction?()
      }
      .disabled(terminateAllTerminalSessionsAction?.isEnabled != true)

      Button("Close Window") {
        // Menu clicks land here from a pane window too; close the tab, never
        // the window (the chord itself is consumed by the pane window).
        if let paneWindow = NSApp.keyWindow as? PaneWindow, let closeTab = paneWindow.closeSelectedTab {
          closeTab()
          return
        }
        NSApplication.shared.keyWindow?.performClose(nil)
      }
      .keyboardShortcut(closeTabEnabled ? nil : .init("w"))
    }
  }
}

private struct TerminateAllTerminalSessionsActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  /// Wired as a scene action so the menu enable state tracks app-wide surface
  /// presence, not the currently-selected worktree.
  var terminateAllTerminalSessionsAction: FocusedAction<Void>? {
    get { self[TerminateAllTerminalSessionsActionKey.self] }
    set { self[TerminateAllTerminalSessionsActionKey.self] = newValue }
  }
}
