import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

struct WorktreeCreationPromptView: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>
  @FocusState private var isBranchFieldFocused: Bool

  var body: some View {
    Form {
      Section {
        TextField("Branch name", text: $store.branchName)
          .focused($isBranchFieldFocused)
          .onSubmit {
            store.send(.createButtonTapped)
          }
      } header: {
        // `NavigationStack` with title and subtitle is bugged inside
        // sheets in macOS 26.*, and this is a nice enough fallback.
        Text("New Worktree")
        Text("Create a branch in `\(store.repositoryName)`.")
      } footer: {
        WorktreeCreationFooter(store: store)
      }
      .headerProminence(.increased)

      Section {
        WorktreeBaseRefField(store: store)

        Toggle(isOn: $store.fetchOrigin) {
          Text("Fetch remote branch")
          Text(
            "Runs `git fetch` to ensure the base branch is up to date before creating the worktree."
          )
        }
        .disabled(store.isSelectedBaseRefLocal)
      }

      Section {
        TextField(
          "Title",
          text: $store.title,
          prompt: Text("Leave blank to use branch name")
        )
        LabeledContent("Color") {
          ColorSwatchRow(color: $store.color)
        }
      } header: {
        Text("Title & Color")
        Text("Optional. Overrides the row title and tint. Leave blank to use the branch name.")
      }

      WorktreeOptionsSection(store: store)
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        if store.isValidating {
          ProgressView()
            .controlSize(.small)
        }
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel (Esc)")
        Button("Create") {
          store.send(.createButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .help("Create (↩)")
        .disabled(store.isValidating)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 420)
    .task { isBranchFieldFocused = true }
    .dismissSystemColorPanelOnDisappear()
  }
}

private struct WorktreeOptionsSection: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>

  var body: some View {
    Section("Advanced", isExpanded: $store.showAdvancedOptions) {
      // Title-string fields so tapping the label focuses the field, matching
      // the branch-name field above.
      TextField("Worktree name", text: $store.worktreeNameOverride, prompt: Text(store.worktreeNamePlaceholder))
      TextField("Parent folder", text: $store.worktreePathOverride, prompt: Text(store.defaultWorktreeBaseDirectory))
    }
  }
}

private struct WorktreeCreationFooter: View {
  let store: StoreOf<WorktreeCreationPromptFeature>

  var body: some View {
    if let message = store.validationMessage ?? store.worktreeNameValidationError, !message.isEmpty {
      Text(message)
        .foregroundStyle(.red)
    } else {
      Text(store.resolvedWorktreeLocationPreview)
        .monospaced()
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct WorktreeBaseRefField: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>

  var body: some View {
    LabeledContent {
      HStack(spacing: 8) {
        if store.isLoadingBranches {
          ProgressView()
            .controlSize(.small)
        }
        Menu {
          WorktreeBaseRefMenuContent(store: store)
        } label: {
          Text(store.baseRefMenuLabel)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
    } label: {
      Text("Base ref")
      Text("The branch or ref the new worktree will be created from.")
    }
  }
}

private struct WorktreeBaseRefMenuContent: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>

  var body: some View {
    WorktreeBaseRefMenuItem(
      store: store,
      ref: nil,
      label: store.automaticBaseRef.isEmpty
        ? Text("Auto")
        : Text(store.automaticBaseRef) + Text(" Auto").foregroundStyle(.secondary)
    )
    if let defaultBranch = store.defaultBranch {
      // Tagged "Local" to distinguish it from the remote-tracking Auto ref above.
      WorktreeBaseRefMenuItem(
        store: store,
        ref: defaultBranch,
        label: Text(defaultBranch) + Text(" Local").foregroundStyle(.secondary)
      )
    }

    Divider()

    if let branchMenu = store.branchMenu {
      if !branchMenu.localBranches.isEmpty {
        Menu("Local") {
          ForEach(branchMenu.localBranches) { node in
            WorktreeBranchNodeMenu(store: store, node: node)
          }
        }
      }
      ForEach(branchMenu.remotes) { remote in
        WorktreeRemoteBranchMenu(store: store, remote: remote)
      }
    } else {
      Text("Loading branches…")
    }
  }
}

private struct WorktreeRemoteBranchMenu: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>
  let remote: BaseRefBranchMenu.Remote

  var body: some View {
    Menu {
      ForEach(remote.branches) { node in
        WorktreeBranchNodeMenu(store: store, node: node)
      }
    } label: {
      Text(remote.name) + Text(" Remote").foregroundStyle(.secondary)
    }
  }
}

private struct WorktreeBranchNodeMenu: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>
  let node: BranchMenuNode

  var body: some View {
    if node.children.isEmpty {
      WorktreeBaseRefMenuItem(store: store, ref: node.ref, label: Text(node.name))
    } else {
      Menu(node.name) {
        // A namespace segment that is also a branch (rare) stays selectable.
        if let ref = node.ref {
          WorktreeBaseRefMenuItem(store: store, ref: ref, label: Text(node.name))
        }
        ForEach(node.children) { child in
          WorktreeBranchNodeMenu(store: store, node: child)
        }
      }
    }
  }
}

private struct WorktreeBaseRefMenuItem: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>
  let ref: String?
  let label: Text

  var body: some View {
    Button {
      store.send(.baseRefSelected(ref))
    } label: {
      if store.selectedBaseRef == ref {
        Label {
          label
        } icon: {
          Image(systemName: "checkmark")
            .accessibilityHidden(true)
        }
      } else {
        label
      }
    }
  }
}
