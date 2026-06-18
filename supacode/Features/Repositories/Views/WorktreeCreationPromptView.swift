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

      WorktreeAppearanceSection(store: store)

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

private struct WorktreeAppearanceSection: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>

  var body: some View {
    Section("Appearance", isExpanded: $store.showAppearanceOptions) {
      TextField("Title", text: $store.title, prompt: Text(store.worktreeNamePlaceholder))
      LabeledContent("Color") {
        ColorSwatchRow(color: $store.color)
      }
    }
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
  @State private var query = ""

  var body: some View {
    LabeledContent {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          if store.isLoadingBranches {
            ProgressView()
              .controlSize(.small)
          }
          // Browse: the full hierarchical menu, kept for when you don't know the
          // branch name up front (large teams / OSS).
          Menu {
            WorktreeBaseRefMenuContent(store: store)
          } label: {
            Text(store.baseRefMenuLabel)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .fixedSize()
          // Search: type any fragment to filter local + remote refs inline.
          TextField("Filter branches", text: $query)
            .textFieldStyle(.roundedBorder)
        }
        if !query.isEmpty {
          WorktreeBaseRefFilterResults(store: store, query: query) { query = "" }
        }
      }
    } label: {
      Text("Base ref")
      Text("The branch or ref the new worktree will be created from.")
    }
  }
}

/// Inline matches under the filter field (#387). A flat row list rather than a
/// popover, so there's no keyboard-focus juggling; the browse Menu still covers
/// "I don't know the name yet".
private struct WorktreeBaseRefFilterResults: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>
  let query: String
  let onSelect: () -> Void

  // Keep the dialog compact: cap visible matches and nudge the user to refine.
  // ponytail: simple prefix cap; add scrolling only if users ask.
  private let limit = 8

  var body: some View {
    if let branchMenu = store.branchMenu {
      let matches = branchMenu.refs(matching: query)
      if matches.isEmpty {
        Text("No matching branches")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(matches.prefix(limit), id: \.self) { ref in
            WorktreeBaseRefResultRow(
              ref: ref,
              isSelected: store.selectedBaseRef == ref
            ) {
              store.send(.baseRefSelected(ref))
              onSelect()
            }
          }
          if matches.count > limit {
            Text("+\(matches.count - limit) more — keep typing to narrow")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.top, 2)
          }
        }
      }
    }
  }
}

private struct WorktreeBaseRefResultRow: View {
  let ref: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: isSelected ? "checkmark" : "arrow.turn.down.right")
          .imageScale(.small)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(ref)
          .monospaced()
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .contentShape(.rect)
      .padding(.vertical, 3)
    }
    .buttonStyle(.plain)
    .help(ref)
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
