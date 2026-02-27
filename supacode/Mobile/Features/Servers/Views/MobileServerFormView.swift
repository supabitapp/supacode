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

        Section("Authentication") {
          Picker("Method", selection: $store.authType) {
            ForEach(ServerFormFeature.State.AuthType.allCases, id: \.self) { type in
              Text(type.rawValue).tag(type)
            }
          }

          switch store.authType {
          case .none:
            EmptyView()
          case .password:
            SecureField("Password", text: $store.password)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          case .sshKey:
            sshKeySection
          }
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
      .task { store.send(.task) }
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
      .sheet(item: $store.scope(state: \.keyGeneration, action: \.keyGeneration)) { keyGenStore in
        SSHKeyGenerationView(store: keyGenStore)
      }
    }
  }

  @ViewBuilder
  private var sshKeySection: some View {
    if store.availableKeys.isEmpty {
      Button("Generate New Key") {
        store.send(.generateKeyTapped)
      }
    } else {
      Picker("Key", selection: $store.selectedKeyID) {
        Text("Select a key").tag(SSHKey.ID?.none)
        ForEach(store.availableKeys) { key in
          Text(key.name).tag(SSHKey.ID?.some(key.id))
        }
      }
      Button("Generate New Key") {
        store.send(.generateKeyTapped)
      }
    }
  }
}
