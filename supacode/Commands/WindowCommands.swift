import SwiftUI

struct WindowCommands: Commands {
  let ghosttyShortcuts: GhosttyShortcutManager
  @FocusedValue(\.closeSurfaceAction) private var closeSurfaceAction
  @FocusedValue(\.closeTabAction) private var closeTabAction

  var body: some Commands {
    let closeSurfaceHotkey = ghosttyShortcuts.keyboardShortcut(for: "close_surface")
    let isCloseSurfaceOverlapping = closeSurfaceHotkey?.key == "w" && closeSurfaceHotkey?.modifiers == .command

    CommandGroup(replacing: .saveItem) {
      Button("Close Terminal", systemImage: "xmark") {
        closeSurfaceAction?()
      }
      // Suppress the Ghostty shortcut when the close-surface action is unavailable so Close Window can claim ⌘W.
      .keyboardShortcut(closeSurfaceAction == nil ? nil : ghosttyShortcuts.keyboardShortcut(for: "close_surface"))
      .disabled(closeSurfaceAction == nil)

      Button("Close Terminal Tab") {
        closeTabAction?()
      }
      .ghosttyKeyboardShortcut("close_tab", in: ghosttyShortcuts)
      .disabled(closeTabAction == nil)

      Button("Close Window") {
        NSApplication.shared.keyWindow?.performClose(nil)
      }
      .keyboardShortcut(!isCloseSurfaceOverlapping || closeSurfaceAction == nil ? .init("w") : nil)
    }
  }
}
