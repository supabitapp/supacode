import ComposableArchitecture
import SwiftUI

struct SSHKeyGenerationView: View {
  @Bindable var store: StoreOf<SSHKeyGenerationFeature>

  var body: some View {
    NavigationStack {
      Form {
        if store.showResult {
          resultSection
        } else {
          inputSection
        }
      }
      .navigationTitle(store.showResult ? "Public Key" : "Generate SSH Key")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if !store.showResult {
            Button("Cancel") {
              store.send(.doneTapped)
            }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          if store.showResult {
            Button("Done") {
              store.send(.doneTapped)
            }
          } else {
            Button("Generate") {
              store.send(.generateTapped)
            }
            .disabled(!store.canGenerate)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var inputSection: some View {
    Section("Key Name") {
      TextField("e.g., My iPad, Work Key", text: $store.keyName)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    Section {
      LabeledContent("Algorithm", value: "Ed25519")
    } footer: {
      Text("Modern, fast, and secure. Recommended for most uses.")
    }

    if store.isGenerating {
      Section {
        HStack {
          ProgressView()
          Text("Generating key...")
        }
      }
    }

    if let error = store.error {
      Section {
        Text(error)
          .foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder
  private var resultSection: some View {
    if let fingerprint = store.fingerprint {
      Section("Fingerprint") {
        Text(fingerprint)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
      }
    }

    Section {
      if let publicKey = store.publicKey {
        Text(publicKey)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)

        Button {
          store.send(.copyPublicKeyTapped)
        } label: {
          Label(
            store.copied ? "Copied" : "Copy to Clipboard",
            systemImage: store.copied ? "checkmark" : "doc.on.doc",
          )
        }
        .buttonStyle(.borderedProminent)
      }
    } header: {
      Text("Public Key")
    } footer: {
      Text("Add this to your server's ~/.ssh/authorized_keys file.")
    }
  }
}
