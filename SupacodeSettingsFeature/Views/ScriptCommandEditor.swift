import SwiftUI

/// Monospaced text editor used by both repository and global script settings panes.
struct ScriptCommandEditor: View {
  @Binding var text: String
  let label: String

  var body: some View {
    PlainTextEditor(text: $text, isMonospaced: true)
      .frame(height: 90)
      .accessibilityLabel(label)
  }
}
