import SwiftUI

struct WindowCommands: Commands {
  let ghosttyShortcuts: GhosttyShortcutManager
  @FocusedValue(\.closeSurfaceAction) private var closeSurfaceAction
  @FocusedValue(\.closeTabAction) private var closeTabAction
  @FocusedValue(\.terminateAllTerminalSessionsAction) private var terminateAllTerminalSessionsAction
  @FocusedValue(\.showNextTabAction) private var showNextTabAction
  @FocusedValue(\.showPreviousTabAction) private var showPreviousTabAction

  var body: some Commands {
    // Tab navigation lives in the Window menu so it matches macOS conventions
    // and can be rebound from System Settings ▸ Keyboard ▸ Shortcuts (issue #418).
    CommandGroup(before: .windowArrangement) {
      Button("Show Next Tab") {
        showNextTabAction?()
      }
      .ghosttyKeyboardShortcut("next_tab", in: ghosttyShortcuts)
      .disabled(showNextTabAction?.isEnabled != true)

      Button("Show Previous Tab") {
        showPreviousTabAction?()
      }
      .ghosttyKeyboardShortcut("previous_tab", in: ghosttyShortcuts)
      .disabled(showPreviousTabAction?.isEnabled != true)

      Divider()
    }

    let closeSurfaceHotkey = ghosttyShortcuts.keyboardShortcut(for: "close_surface")
    let isCloseSurfaceOverlapping = closeSurfaceHotkey?.key == "w" && closeSurfaceHotkey?.modifiers == .command

    let closeSurfaceEnabled = closeSurfaceAction?.isEnabled == true
    CommandGroup(replacing: .saveItem) {
      Button("Close Terminal", systemImage: "xmark") {
        closeSurfaceAction?()
      }
      // Suppress the Ghostty shortcut when the close-surface action is unavailable so Close Window can claim ⌘W.
      .keyboardShortcut(closeSurfaceEnabled ? ghosttyShortcuts.keyboardShortcut(for: "close_surface") : nil)
      .disabled(!closeSurfaceEnabled)

      Button("Close Terminal Tab") {
        closeTabAction?()
      }
      .ghosttyKeyboardShortcut("close_tab", in: ghosttyShortcuts)
      .disabled(closeTabAction?.isEnabled != true)

      Button("Terminate All Terminal Sessions…") {
        terminateAllTerminalSessionsAction?()
      }
      .disabled(terminateAllTerminalSessionsAction?.isEnabled != true)

      Button("Close Window") {
        NSApplication.shared.keyWindow?.performClose(nil)
      }
      .keyboardShortcut(!isCloseSurfaceOverlapping || !closeSurfaceEnabled ? .init("w") : nil)
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

private struct ShowNextTabActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var showNextTabAction: FocusedAction<Void>? {
    get { self[ShowNextTabActionKey.self] }
    set { self[ShowNextTabActionKey.self] = newValue }
  }
}

private struct ShowPreviousTabActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var showPreviousTabAction: FocusedAction<Void>? {
    get { self[ShowPreviousTabActionKey.self] }
    set { self[ShowPreviousTabActionKey.self] = newValue }
  }
}
