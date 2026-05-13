import SwiftUI

extension View {
  /// Applies the Ghostty-configured keyboard shortcut for `binding` (e.g. `"new_tab"`,
  /// `"new_split:right"`). Returns the view unchanged if Ghostty has no binding for the action.
  ///
  /// Uses SwiftUI's nilable `keyboardShortcut(_:)` so the wrapped view keeps a stable type when
  /// the binding hydrates from disk — the conditional `if let { content.keyboardShortcut(_:) }`
  /// form flips between view types via `_ConditionalContent` and strips menu arrangement items
  /// on Tahoe. Mirrors `appKeyboardShortcut` for Supacode-owned shortcuts.
  ///
  /// The manager is passed explicitly because `@Environment` does not propagate into `Commands`
  /// bodies on macOS; resolving through the env would crash for File-menu items.
  func ghosttyKeyboardShortcut(_ binding: String, in shortcuts: GhosttyShortcutManager) -> some View {
    keyboardShortcut(shortcuts.keyboardShortcut(for: binding))
  }
}
