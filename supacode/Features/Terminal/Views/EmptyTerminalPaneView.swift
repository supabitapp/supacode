import SupacodeSettingsShared
import SwiftUI

struct EmptyTerminalPaneView: View {
  let message: String
  /// The recovery hint below the message; the default names the strip's
  /// new-tab button, so tab-less states must pass an affordance that exists.
  var hint: Text = Text("Use the \(Text("+").bold()) button to open a terminal.")

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
        hint
          .appFont(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
