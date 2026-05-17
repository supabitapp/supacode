import SwiftUI

struct WindowCommands: Commands {
  let ghosttyShortcuts: GhosttyShortcutManager
  @FocusedValue(\.closeSurfaceAction) private var closeSurfaceAction
  @FocusedValue(\.closeTabAction) private var closeTabAction

  var body: some Commands {
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

      Button("Close Window") {
        NSApplication.shared.keyWindow?.performClose(nil)
      }
      .keyboardShortcut(!isCloseSurfaceOverlapping || !closeSurfaceEnabled ? .init("w") : nil)
    }
  }
}
