import ComposableArchitecture
import SwiftUI

struct MobileServerFormView: View {
  @Bindable var store: StoreOf<ServerFormFeature>

  var body: some View {
    NavigationStack {
      Form {
        Section("Server") {
          TextField("Display name", text: $store.name)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          TextField("Hostname", text: $store.host)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          TextField("Username", text: $store.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          TextField("Port", text: $store.port)
            .keyboardType(.numberPad)
            .autocorrectionDisabled()
        }

        Section("Optional") {
          TextField("Default startup command", text: $store.defaultCommand)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }

        if let error = store.validationError {
          Text(error)
            .foregroundStyle(.red)
            .font(.footnote)
        }
      }
      .navigationTitle(store.isEditing ? "Edit Server" : "Add Server")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            store.send(.cancel)
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            store.send(.save)
          }
          .disabled(!store.canSave)
        }
        if store.isEditing {
          ToolbarItem(placement: .bottomBar) {
            Button("Delete", role: .destructive) {
              store.send(.delete)
            }
          }
        }
      }
    }
  }
}
