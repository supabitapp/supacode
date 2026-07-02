import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI
import UniformTypeIdentifiers

private nonisolated let cloneFormLogger = SupaLogger("Clone")

/// Clone form sheet: shows the live destination, streams clone progress in the
/// bottom bar, and surfaces failures in the footer with the sheet kept open.
struct CloneRepositoryFormView: View {
  @Bindable var store: StoreOf<CloneRepositoryFormFeature>
  @State private var isChoosingLocation = false

  var body: some View {
    Form {
      Section {
        TextField("Repository URL", text: $store.repositoryURL)
          .help("An https or ssh git URL to clone")
          .disabled(store.isCloning)
        LabeledContent {
          Button {
            isChoosingLocation = true
          } label: {
            (store.cloneLocationPath.isEmpty
              ? Text("Choose…")
              : Text("`\(store.cloneLocationPath)`"))
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .disabled(store.isCloning)
          .help("Choose the parent folder for the clone")
        } label: {
          Text("Clone to Location")
          Text("The folder that will contain the clone.")
        }
        LabeledContent {
          TextField(store.derivedFolderName, text: $store.folderName)
            .labelsHidden()
            .disabled(store.isCloning)
        } label: {
          Text("Folder Name")
          if let destination = store.destinationURL {
            Text("Clones into `\(destination.path(percentEncoded: false))`.")
          } else {
            Text("Defaults to the repository name.")
          }
        }
      } header: {
        // `NavigationStack` title + subtitle is bugged inside sheets on macOS
        // 26.*, so the header carries the title (mirrors the remote form).
        Text("Clone Repository")
        Text("Clone a remote repository into a local folder and add it.")
      } footer: {
        if let message = store.footerMessage, !message.isEmpty {
          Text(message).foregroundStyle(.red)
        }
      }
      .headerProminence(.increased)

      CloneRepositoryAdvancedSection(store: store)
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        if store.isCloning {
          ProgressView().controlSize(.small)
          if let progress = store.progressLine, !progress.isEmpty {
            Text(store.compactProgressLine ?? progress)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
              .help(progress)
          }
        }
        Spacer()
        Button("Cancel", role: .cancel) { store.send(.cancelButtonTapped) }
          .keyboardShortcut(.cancelAction)
          .help("Cancel (Esc)")
        Button("Clone") { store.send(.submitButtonTapped) }
          .keyboardShortcut(.defaultAction)
          .disabled(!store.canSubmit)
          .help("Clone the repository into the chosen folder (Return)")
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 460)
    .fileImporter(isPresented: $isChoosingLocation, allowedContentTypes: [.folder]) { result in
      switch result {
      case .success(let url):
        store.send(.locationSelected(url))
      case .failure(let error):
        cloneFormLogger.error("clone location picker failed: \(error.localizedDescription)")
      }
    }
  }
}

/// Optional branch and depth, collapsed by default so the primary flow stays
/// url + location (mirrors the New Worktree prompt's Advanced section).
private struct CloneRepositoryAdvancedSection: View {
  @Bindable var store: StoreOf<CloneRepositoryFormFeature>

  var body: some View {
    Section("Advanced", isExpanded: $store.showAdvancedOptions) {
      LabeledContent {
        TextField("Optional", text: $store.branch)
          .labelsHidden()
          .disabled(store.isCloning)
      } label: {
        Text("Branch")
        Text("Clones the default branch when empty.")
      }
      LabeledContent {
        TextField("Optional", text: $store.depth)
          .labelsHidden()
          .disabled(store.isCloning)
      } label: {
        Text("Depth")
        Text("Creates a shallow clone of the given depth.")
      }
    }
  }
}
