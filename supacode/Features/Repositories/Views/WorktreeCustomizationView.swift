import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

struct WorktreeCustomizationView: View {
  @Bindable var store: StoreOf<WorktreeCustomizationFeature>
  @FocusState private var isTitleFocused: Bool

  var body: some View {
    Form {
      Section {
        TextField("Title", text: $store.title, prompt: Text(store.defaultName))
          .focused($isTitleFocused)
          .onSubmit {
            store.send(.saveButtonTapped)
          }
        LabeledContent("Color") {
          ColorSwatchRow(color: $store.color)
        }
      } header: {
        Text("Customize Appearance")
        Text("Override the sidebar title and tint for `\(store.defaultName)`.")
      }
      .headerProminence(.increased)
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel (Esc)")
        Button("Save") {
          store.send(.saveButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .help("Save (↩)")
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 420)
    .task { isTitleFocused = true }
    .dismissSystemColorPanelOnDisappear()
  }
}
