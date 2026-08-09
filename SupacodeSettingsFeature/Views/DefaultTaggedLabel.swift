import SwiftUI

/// Picker-row label with the shared secondary "Default" marker on the
/// built-in default option.
struct DefaultTaggedLabel: View {
  let label: String
  let isDefault: Bool

  var body: some View {
    if isDefault {
      Text("\(label) \(Text("Default").foregroundStyle(.secondary))")
    } else {
      Text(label)
    }
  }
}
