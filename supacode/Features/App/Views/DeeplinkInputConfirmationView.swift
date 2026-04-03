import ComposableArchitecture
import SwiftUI

struct DeeplinkInputConfirmationView: View {
  @Bindable var store: StoreOf<DeeplinkInputConfirmationFeature>

  var body: some View {
    Form {
      Section {
        MessageView(message: store.message)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("Run Deeplink Command")
        Text(subtitle)
      } footer: {
        Toggle(isOn: $store.alwaysAllow) {
          Text("Always allow deeplink commands without confirmation.")
        }
        .help(
          "When enabled, deeplinks can run commands and perform destructive actions without asking for confirmation.")
      }
      .headerProminence(.increased)
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        Spacer()
        Button("Cancel") {
          store.send(.cancelTapped)
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel (Esc)")
        Button("Run Command") {
          store.send(.runTapped)
        }
        .keyboardShortcut(.defaultAction)
        .help("Run Command (↩)")
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 420)
  }

  private var subtitle: LocalizedStringKey {
    guard let repoName = store.repositoryName else { return "Run command in `\(store.worktreeName)`." }
    return "Run command in `\(store.worktreeName)` from `\(repoName)`."
  }
}

private struct MessageView: View {
  let message: DeeplinkConfirmationMessage

  var body: some View {
    switch message {
    case .command(let text):
      Text(text).monospaced()
    case .confirmation(let text):
      Text(text)
    }
  }
}
