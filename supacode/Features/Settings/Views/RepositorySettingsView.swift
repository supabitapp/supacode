import ComposableArchitecture
import SwiftUI

struct RepositorySettingsView: View {
  @Bindable var store: StoreOf<RepositorySettingsFeature>
  @State private var isBranchPickerPresented = false
  @State private var branchSearchText = ""

  var body: some View {
    let baseRefOptions =
      store.branchOptions.isEmpty ? [store.defaultWorktreeBaseRef] : store.branchOptions
    let settings = $store.settings
    Form {
      Section {
        if store.isBranchDataLoaded {
          Button {
            branchSearchText = ""
            isBranchPickerPresented = true
          } label: {
            HStack {
              Text(store.settings.worktreeBaseRef ?? "Automatic (\(store.defaultWorktreeBaseRef))")
                .foregroundStyle(.primary)
              Spacer()
              Image(systemName: "chevron.up.chevron.down")
                .foregroundStyle(.secondary)
                .font(.caption)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .popover(isPresented: $isBranchPickerPresented) {
            BranchPickerPopover(
              searchText: $branchSearchText,
              options: baseRefOptions,
              automaticLabel: "Automatic (\(store.defaultWorktreeBaseRef))",
              selection: store.settings.worktreeBaseRef,
              onSelect: { ref in
                store.settings.worktreeBaseRef = ref
                isBranchPickerPresented = false
              }
            )
          }
        } else {
          ProgressView()
            .controlSize(.small)
        }
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Branch new workspaces from")
          Text("Each workspace is an isolated copy of your codebase.")
            .foregroundStyle(.secondary)
        }
      }
      Section {
        Toggle(
          "Copy ignored files to new worktrees",
          isOn: settings.copyIgnoredOnWorktreeCreate
        )
        .disabled(store.isBareRepository)
        Toggle(
          "Copy untracked files to new worktrees",
          isOn: settings.copyUntrackedOnWorktreeCreate
        )
        .disabled(store.isBareRepository)
        if store.isBareRepository {
          Text("Copy flags are ignored for bare repositories.")
            .foregroundStyle(.secondary)
        }
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Worktree")
          Text("Applies when creating a new worktree")
            .foregroundStyle(.secondary)
        }
      }
      Section {
        Picker(
          "Merge strategy",
          selection: settings.pullRequestMergeStrategy
        ) {
          ForEach(PullRequestMergeStrategy.allCases) { strategy in
            Text(strategy.title)
              .tag(strategy)
          }
        }
        .labelsHidden()
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Pull Requests")
          Text("Used when merging PRs from the command palette")
            .foregroundStyle(.secondary)
        }
      }
      Section {
        ZStack(alignment: .topLeading) {
          TextEditor(
            text: settings.setupScript
          )
          .font(.body)
          .frame(minHeight: 120)
          if store.settings.setupScript.isEmpty {
            Text("claude --dangerously-skip-permissions")
              .foregroundStyle(.secondary)
              .padding(.leading, 6)
              .font(.body)
              .allowsHitTesting(false)
          }
        }
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Setup Script")
          Text("Initial setup script that will be launched once after worktree creation")
            .foregroundStyle(.secondary)
        }
      }
      Section {
        ZStack(alignment: .topLeading) {
          TextEditor(
            text: settings.runScript
          )
          .font(.body)
          .frame(minHeight: 120)
          if store.settings.runScript.isEmpty {
            Text("npm run dev")
              .foregroundStyle(.secondary)
              .padding(.leading, 6)
              .font(.body)
              .allowsHitTesting(false)
          }
        }
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Run Script")
          Text("Run script launched on demand from the toolbar")
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      store.send(.task)
    }
  }
}

private struct BranchPickerPopover: View {
  @Binding var searchText: String
  let options: [String]
  let automaticLabel: String
  let selection: String?
  let onSelect: (String?) -> Void
  @FocusState private var isSearchFocused: Bool

  var filteredOptions: [String] {
    if searchText.isEmpty { return options }
    return options.filter { $0.localizedCaseInsensitiveContains(searchText) }
  }

  var body: some View {
    VStack(spacing: 0) {
      TextField("Filter branches...", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .focused($isSearchFocused)
        .padding(8)
      Divider()
      List {
        Button {
          onSelect(nil)
        } label: {
          HStack {
            Text(automaticLabel)
            Spacer()
            if selection == nil {
              Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            }
          }
          .padding(.vertical, 6)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        ForEach(filteredOptions, id: \.self) { ref in
          Button {
            onSelect(ref)
          } label: {
            HStack {
              Text(ref)
              Spacer()
              if selection == ref {
                Image(systemName: "checkmark")
                  .foregroundStyle(.tint)
                  .accessibilityHidden(true)
              }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .listStyle(.plain)
    }
    .frame(width: 300, height: 350)
    .onAppear { isSearchFocused = true }
  }
}
