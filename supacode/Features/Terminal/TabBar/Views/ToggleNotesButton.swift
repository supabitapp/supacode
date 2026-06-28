import SwiftUI

/// Tab-bar toolbar toggle that opens/closes the notes panel for the selected
/// tab. Follows the `TerminalTabBarAccessoryButton` template; tints when open so
/// it reads as a toggle. Added alongside the split buttons — nothing is removed.
struct ToggleNotesButton: View {
  let isOpen: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Notas", systemImage: "note.text")
        .labelStyle(.iconOnly)
        .frame(minWidth: TerminalTabBarMetrics.barHeight, minHeight: TerminalTabBarMetrics.barHeight)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .foregroundStyle(isOpen ? Color.accentColor : Color.secondary)
    .help("Notas")
  }
}
