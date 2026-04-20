import SwiftUI

struct EmptyTerminalPaneView: View {
  let message: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "apple.terminal.on.rectangle")
        .font(.title)
        .imageScale(.large)
        .accessibilityHidden(true)
        .foregroundStyle(.secondary)
      VStack(spacing: 4) {
        Text(message)
          .font(.title3)
        Text("Use the \(Text("+").bold()) button to open a terminal.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .multilineTextAlignment(.center)
    .background(Color(nsColor: .windowBackgroundColor))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
