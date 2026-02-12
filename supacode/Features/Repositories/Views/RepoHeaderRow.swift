import SwiftUI

struct RepoHeaderRow: View {
  let name: String
  let isRemoving: Bool
  let shortcutHint: String?
  var body: some View {
    HStack {
      Text(name)
        .foregroundStyle(.secondary)
      if isRemoving {
        Text("Removing...")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 4)
      if let shortcutHint {
        ShortcutHintView(text: shortcutHint, color: .secondary)
      }
    }
  }
}
