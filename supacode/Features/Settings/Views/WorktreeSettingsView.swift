import ComposableArchitecture
import SwiftUI

struct WorktreeSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    let defaultPath = SupacodePaths.reposDirectory.path(percentEncoded: false)
    let resolvedBase =
      SupacodePaths.normalizedWorktreeBaseDirectoryPath(
        store.defaultWorktreeBaseDirectoryPath
      ) ?? defaultPath
    let examplePath = "\(resolvedBase)*/**/*"
    Form {
      Section {
        Toggle(isOn: $store.promptForWorktreeCreation) {
          Text("Prompt for branch name on creation")
          Text("Choose the branch name and base ref before creating the worktree.")
        }
        Toggle(isOn: $store.fetchOriginBeforeWorktreeCreation) {
          Text("Fetch remote branch before creating worktree")
          Text("Runs git fetch to ensure the base branch is up to date.")
        }
        TextField(
          text: $store.defaultWorktreeBaseDirectoryPath,
          prompt: Text(defaultPath)
        ) {
          Text("Default directory").monospaced(false)
          Text("Parent path for new worktrees.").monospaced(false)
        }.monospaced()
      } footer: {
        Text("e.g., `\(examplePath)`")
      }
      Section {
        Toggle(isOn: $store.copyIgnoredOnWorktreeCreate) {
          Text("Copy ignored files to new worktrees")
          Text("Copies gitignored files from the main worktree.")
        }
        Toggle(isOn: $store.copyUntrackedOnWorktreeCreate) {
          Text("Copy untracked files to new worktrees")
          Text("Copies untracked files from the main worktree.")
        }
      }
      Section("Clean-up") {
        Picker(
          "Auto-delete archived worktrees",
          selection: Binding(
            get: { store.autoDeleteArchivedWorktreesAfterDays },
            set: { store.send(.requestAutoDeleteDaysChange($0)) }
          )
        ) {
          Text("Never").tag(AutoDeletePeriod?.none)
          ForEach(AutoDeletePeriod.allCases, id: \.rawValue) { period in
            Text(period.label).tag(AutoDeletePeriod?.some(period))
          }
        }
      }
      Section {
        Toggle(isOn: $store.deleteBranchOnDeleteWorktree) {
          Text("Delete local branch with worktree")
          Text("Removes the local branch along with the worktree. Remote branches must be deleted on GitHub.")
          Text("Uncommitted changes will be lost.").foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("Worktrees")
  }
}
