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
  @State private var highlightedIndex = 0
  // Leading index of the rendered window; slides as the highlight crosses an edge so the list never scrolls.
  @State private var windowStart = 0

  // Render a fixed window and paginate the rest to keep the dialog compact.
  private let pageSize = 8

  private var matches: [String] {
    store.branchMenu?.refs(matching: query) ?? []
  }

  var body: some View {
    // Flatten once per render; the window derivations below all read this local.
    let matches = matches
    let windowEnd = min(windowStart + pageSize, matches.count)
    let visibleMatches = windowStart < matches.count ? Array(matches[windowStart..<windowEnd]) : []
    // Full-width row so the search field fills and the menu reaches the trailing edge.
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Base ref")
        Text("The branch or ref the new worktree will be created from.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        if store.isLoadingBranches {
          ProgressView()
            .controlSize(.small)
        }
        TextField("Search…", text: $query, prompt: Text("Search…"))
          .labelsHidden()
          .textFieldStyle(.plain)
          .frame(maxWidth: .infinity, alignment: .leading)
          .onKeyPress(.downArrow) { moveHighlight(by: 1) }
          .onKeyPress(.upArrow) { moveHighlight(by: -1) }
          .onKeyPress(.return) { commitHighlighted() }
        // Browse: the hierarchical menu, kept for when you don't know the branch name up front.
        Menu {
          WorktreeBaseRefMenuContent(store: store)
        } label: {
          Text(store.baseRefMenuLabel)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        // Cap and pin trailing so a long ref can't crowd the search field yet still grazes the right edge.
        .frame(maxWidth: 160, alignment: .trailing)
        .layoutPriority(1)
        .help(store.baseRefMenuLabel)
      }
      // Fill the row so the menu reaches the trailing edge.
      .frame(maxWidth: .infinity)
      if !query.isEmpty {
        WorktreeBaseRefFilterResults(
          store: store,
          matches: visibleMatches,
          highlightedIndex: highlightedIndex - windowStart,
          rangeStart: windowStart + 1,
          rangeEnd: windowEnd,
          total: matches.count,
          onSelect: select
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: query) {
      highlightedIndex = 0
      windowStart = 0
    }
  }

  private func moveHighlight(by delta: Int) -> KeyPress.Result {
    let matches = matches
    guard !query.isEmpty, !matches.isEmpty else { return .ignored }
    let newIndex = max(0, min(matches.count - 1, highlightedIndex + delta))
    highlightedIndex = newIndex
    if newIndex < windowStart {
      windowStart = newIndex
    } else if newIndex >= windowStart + pageSize {
      windowStart = newIndex - pageSize + 1
    }
    return .handled
  }

  private func commitHighlighted() -> KeyPress.Result {
    // Let an empty query fall through to the form's default action; otherwise
    // swallow Return so a no-match query never creates the worktree by accident.
    guard !query.isEmpty else { return .ignored }
    let matches = matches
    if matches.indices.contains(highlightedIndex) {
      select(matches[highlightedIndex])
    }
    return .handled
  }

  private func select(_ ref: String) {
    store.send(.baseRefSelected(ref))
    query = ""
  }
}

/// Inline matches under the filter field (#387). A flat row list rather than a
/// popover, so there's no keyboard-focus juggling; the browse Menu still covers
/// "I don't know the name yet".
private struct WorktreeBaseRefFilterResults: View {
  let store: StoreOf<WorktreeCreationPromptFeature>
  /// The rendered window of refs, not the full match set.
  let matches: [String]
  /// Highlighted row index within the window.
  let highlightedIndex: Int
  let rangeStart: Int
  let rangeEnd: Int
  let total: Int
  let onSelect: (String) -> Void

  var body: some View {
    if matches.isEmpty {
      Text("No matching branches")
        .font(.callout)
        .foregroundStyle(.secondary)
    } else {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(matches.enumerated()), id: \.element) { index, ref in
            WorktreeBaseRefResultRow(
              ref: ref,
              remoteNames: store.remoteNames,
              isSelected: store.selectedBaseRef == ref,
              isHighlighted: index == highlightedIndex
            ) {
              onSelect(ref)
            }
          }
        }
        // Cancel the rows' inset so the text aligns with the form while the highlight bleeds into the margin.
        .padding(.horizontal, -4)
        if total > matches.count {
          Text("\(rangeStart) to \(rangeEnd), out of \(total)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
      }
    }
  }
}

private struct WorktreeBaseRefResultRow: View {
  let ref: String
  let remoteNames: [String]
  let isSelected: Bool
  let isHighlighted: Bool
  let action: () -> Void

  private var display: (name: String, scope: String) {
    BaseRefBranchMenu.rowDisplay(for: ref, remoteNames: remoteNames)
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(display.name)
          .monospaced()
          .underline(isSelected)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 8)
        Text(display.scope)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 3)
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .background(isHighlighted ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 5))
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
        : Text("\(store.automaticBaseRef) \(Text("Auto").foregroundStyle(.secondary))")
    )
    if let defaultBranch = store.defaultBranch {
      // Tagged "Local" to distinguish it from the remote-tracking Auto ref above.
      WorktreeBaseRefMenuItem(
        store: store,
        ref: defaultBranch,
        label: Text("\(defaultBranch) \(Text("Local").foregroundStyle(.secondary))")
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
      Text("\(remote.name) \(Text("Remote").foregroundStyle(.secondary))")
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
