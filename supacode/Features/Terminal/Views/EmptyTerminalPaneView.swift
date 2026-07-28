import SupacodeSettingsShared
import SwiftUI

struct EmptyTerminalPaneView: View {
  let message: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "apple.terminal.on.rectangle")
        .appFont(.title)
        .imageScale(.large)
        .accessibilityHidden(true)
        .foregroundStyle(.secondary)
      VStack(spacing: 4) {
        Text(message)
          .appFont(.title3)
        Text("Use the \(Text("+").bold()) button to open a terminal.")
          .appFont(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
