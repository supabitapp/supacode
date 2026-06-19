import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Add / edit form for a remote (SSH) repository connection. Mirrors the New
/// Worktree prompt: a grouped form with a title/subtitle header, a bottom
/// button bar, and validation surfaced in the section footer (the sheet stays
/// open on a failed connect rather than dismissing). Renaming is handled
/// through Customize Appearance, so there is no display-name field.
struct RemoteConnectionFormView: View {
  @Bindable var store: StoreOf<RemoteConnectionFormFeature>

  var body: some View {
    Form {
      Section {
        TextField("Server", text: $store.server)
          .help("An ~/.ssh/config alias or a hostname Supacode will pass to ssh")
        LabeledContent {
          TextField("Port", text: $store.port).labelsHidden()
        } label: {
          Text("Port")
          Text("Defaults to 22.")
        }
        LabeledContent {
          TextField("User", text: $store.username).labelsHidden()
        } label: {
          Text("User")
          Text("Defaults to your SSH config.")
        }
        LabeledContent {
          TextField("Path", text: $store.remotePath).labelsHidden()
        } label: {
          Text("Path")
          Text("`~` will be expanded at creation time.")
        }
      } header: {
        // `NavigationStack` with title and subtitle is bugged inside
        // sheets in macOS 26.*, and this is a nice enough fallback.
        Text(store.isEditing ? "Edit Connection" : "Connect to Remote Host")
        Text("Open a repository or folder on another machine over SSH.")
      } footer: {
        if let message = store.validationMessage, !message.isEmpty {
          Text(message).foregroundStyle(.red)
        }
      }
      .headerProminence(.increased)
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        if store.isValidating {
          ProgressView().controlSize(.small)
        }
        Spacer()
        Button("Cancel", role: .cancel) { store.send(.cancelButtonTapped) }
          .keyboardShortcut(.cancelAction)
          .help("Cancel (Esc)")
        Button(store.isEditing ? "Save" : "Add") { store.send(.submitButtonTapped) }
          .keyboardShortcut(.defaultAction)
          .disabled(!store.canSubmit)
          .help(store.isEditing ? "Save the connection" : "Add this remote repository to the sidebar")
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 420)
  }
}
