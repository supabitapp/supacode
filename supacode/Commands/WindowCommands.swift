import Sharing
import SupacodeSettingsShared
import SwiftUI

struct WindowCommands: Commands {
  @Shared(.settingsFile) private var settingsFile
  @FocusedValue(\.closeTabAction) private var closeTabAction
  @FocusedValue(\.terminateAllTerminalSessionsAction) private var terminateAllTerminalSessionsAction

  var body: some Commands {
    let closeTab = AppShortcuts.closeTab.effective(from: settingsFile.global.shortcutOverrides)
    let closeTabEnabled = closeTabAction?.isEnabled == true && closeTab != nil
    let isCloseTabOverlapping = closeTab?.display == "⌘W"
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
        // In a pane window the chord falls back here when the focused values
        // do not propagate; it must still close the tab, never the window.
        if let paneWindow = NSApp.keyWindow as? PaneWindow, let closeTab = paneWindow.closeSelectedTab {
          closeTab()
          return
        }
        NSApplication.shared.keyWindow?.performClose(nil)
      }
      .keyboardShortcut(!isCloseTabOverlapping || !closeTabEnabled ? .init("w") : nil)
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
