import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Accessibility pane. Holds the chrome text size, which is separate from the
/// terminal's own font zoom.
public struct AccessibilitySettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  public init(store: StoreOf<SettingsFeature>) {
    self.store = store
  }

  public var body: some View {
    Form {
      Section {
        Picker(selection: $store.chromeTextSize) {
          ForEach(ChromeTextSize.allCases) { size in
            Text(size.label).tag(size)
          }
        } label: {
          Text("Text size")
          Text("Sizes the sidebar, tab bar, toolbars, and Settings text. The terminal has its own font size.")
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Accessibility")
  }
}
