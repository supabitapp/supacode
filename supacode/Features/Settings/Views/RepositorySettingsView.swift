import ComposableArchitecture
import SwiftUI

struct RepositorySettingsView: View {
  @Bindable var store: StoreOf<RepositorySettingsFeature>

  var body: some View {
    let baseRefOptions =
      store.branchOptions.isEmpty ? [store.defaultWorktreeBaseRef] : store.branchOptions
    let settings = $store.settings
    let worktreeBaseDirectoryPath = Binding(
      get: { settings.worktreeBaseDirectoryPath.wrappedValue ?? "" },
      set: { settings.worktreeBaseDirectoryPath.wrappedValue = $0 },
    )
    let exampleWorktreePath = store.exampleWorktreePath
    Form {
      Section {
        if store.isBranchDataLoaded {
          Picker(selection: $store.settings.worktreeBaseRef) {
            Text("Auto \(Text(store.defaultWorktreeBaseRef).foregroundStyle(.secondary))")
              .tag(String?.none)
            ForEach(baseRefOptions, id: \.self) { ref in
              Text(ref).tag(Optional(ref))
            }
          } label: {
            Text("Base branch")
            Text("New worktrees branch from this ref.")
          }
        } else {
          LabeledContent {
            ProgressView()
              .controlSize(.small)
          } label: {
            Text("Base branch")
            Text("New worktrees branch from this ref.")
          }
        }
      }
      Section {
        Picker(selection: settings.copyIgnoredOnWorktreeCreate) {
          Text("Global \(Text(store.globalCopyIgnoredOnWorktreeCreate ? "Yes" : "No").foregroundStyle(.secondary))")
            .tag(Bool?.none)
          Text("Yes").tag(Bool?.some(true))
          Text("No").tag(Bool?.some(false))
        } label: {
          Text("Copy ignored files to new worktrees")
          Text("Copies gitignored files from the main worktree.")
        }
        .disabled(store.isBareRepository)
        Picker(selection: settings.copyUntrackedOnWorktreeCreate) {
          Text("Global \(Text(store.globalCopyUntrackedOnWorktreeCreate ? "Yes" : "No").foregroundStyle(.secondary))")
            .tag(Bool?.none)
          Text("Yes").tag(Bool?.some(true))
          Text("No").tag(Bool?.some(false))
        } label: {
          Text("Copy untracked files to new worktrees")
          Text("Copies untracked files from the main worktree.")
        }
        .disabled(store.isBareRepository)
        if store.isBareRepository {
          Text("Copy flags are ignored for bare repositories.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
        }
        TextField(
          text: worktreeBaseDirectoryPath,
          prompt: Text(
            SupacodePaths.worktreeBaseDirectory(
              for: store.rootURL,
              globalDefaultPath: store.globalDefaultWorktreeBaseDirectoryPath,
              repositoryOverridePath: nil
            ).path(percentEncoded: false)
          )
        ) {
          Text("Default directory").monospaced(false)
          Text("Parent path for new worktrees.").monospaced(false)
        }.monospaced()
      } header: {
        Text("Worktree")
      } footer: {
        Text("e.g., `\(exampleWorktreePath)`")
      }
      Section("Pull Requests") {
        Picker(selection: settings.pullRequestMergeStrategy) {
          Text("Global \(Text(store.globalPullRequestMergeStrategy.title).foregroundStyle(.secondary))")
            .tag(PullRequestMergeStrategy?.none)
          ForEach(PullRequestMergeStrategy.allCases) { strategy in
            Text(strategy.title)
              .tag(PullRequestMergeStrategy?.some(strategy))
          }
        } label: {
          Text("Merge strategy")
          Text("Used when merging PRs from the command palette.")
        }
      }
      Section("Environment Variables") {
        ScriptEnvironmentRow(
          name: "SUPACODE_WORKTREE_PATH",
          description: "Path to the active worktree."
        )
        ScriptEnvironmentRow(
          name: "SUPACODE_ROOT_PATH",
          description: "Path to the repository root."
        )
      }
      ScriptSection(
        title: "Setup Script",
        subtitle: "Runs once after worktree creation.",
        text: settings.setupScript,
        placeholder: "claude --dangerously-skip-permissions"
      )
      ScriptSection(
        title: "Run Script",
        subtitle: "Launched on demand from the toolbar.",
        text: settings.runScript,
        placeholder: "npm run dev"
      )
      ScriptSection(
        title: "Archive Script",
        subtitle: "Runs before a worktree is archived.",
        text: settings.archiveScript,
        placeholder: "docker compose down"
      )
      ScriptSection(
        title: "Delete Script",
        subtitle: "Runs before a worktree is deleted.",
        text: settings.deleteScript,
        placeholder: "docker compose down"
      )
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .task {
      store.send(.task)
    }
  }
}

// MARK: - Script section.

private struct ScriptSection: View {
  let title: String
  let subtitle: String
  let text: Binding<String>
  let placeholder: String

  var body: some View {
    Section {
      TextEditor(text: text)
        .monospaced()
        .textEditorStyle(.plain)
        .autocorrectionDisabled()
        .frame(height: 112)
        .accessibilityLabel(title)
    } header: {
      Text(title)
      Text(subtitle)
    } footer: {
      Text("e.g., `\(placeholder)`")
    }
  }
}

// MARK: - Environment row.

private struct ScriptEnvironmentRow: View {
  let name: String
  let description: String

  var body: some View {
    LabeledContent {
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
      } label: {
        Image(systemName: "doc.on.doc")
          .accessibilityLabel("Copy variable key")
      }
      .buttonStyle(.borderless)
      .help("Copy variable key.")
    } label: {
      Text(name).monospaced()
      Text(description)
    }
  }
}
