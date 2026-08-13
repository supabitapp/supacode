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
      WorktreeUpstreamField(store: store)
    }
  }
}

private struct WorktreeCreationFooter: View {
  let store: StoreOf<WorktreeCreationPromptFeature>

  var body: some View {
    if let message = store.validationMessage ?? store.worktreeNameValidationError, !message.isEmpty {
      Text(message)
        .foregroundStyle(.red)
      // Only rendered when validation found an existing branch no worktree
      // holds; a branch checked out elsewhere sets the message without an offer.
      if let branch = store.branchReuseOffer {
        Button("Reuse existing branch") {
          store.send(.reuseExistingBranchButtonTapped)
        }
        .help("Check out the existing '\(branch)' branch in the new worktree instead of creating a new branch.")
        .disabled(store.isValidating)
      }
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
    WorktreeRefPickerField(
      title: "Base ref",
      caption: "The branch or ref the new worktree will be created from.",
      menuLabel: store.baseRefMenuLabel,
      branchMenu: store.branchMenu,
      remoteNames: store.remoteNames,
      selectedRef: store.selectedBaseRef,
      onSelect: { store.send(.baseRefSelected($0)) },
      topRows: { WorktreeBaseRefTopRows(store: store) }
    )
  }
}

private struct WorktreeUpstreamField: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>

  var body: some View {
    WorktreeRefPickerField(
      title: "Upstream",
      caption: "The branch the new branch tracks. Auto leaves it to Git, which tracks a remote base ref by default.",
      menuLabel: store.upstreamMenuLabel,
      branchMenu: store.upstreamBranchMenu,
      remoteNames: store.remoteNames,
      selectedRef: store.selectedUpstreamBranch,
      onSelect: { store.send(.upstreamSelected(.branch($0))) },
      topRows: { WorktreeUpstreamTopRows(store: store) }
    )
  }
}

/// Shared search + browse picker over the branch inventory; the callers inject
/// the non-branch top rows (Auto / None / quick picks) and the selection action.
private struct WorktreeRefPickerField<TopRows: View>: View {
  let title: String
  let caption: String
  let menuLabel: String
  let branchMenu: BaseRefBranchMenu?
  let remoteNames: [String]
  let selectedRef: String?
  let onSelect: (String) -> Void
  @ViewBuilder let topRows: TopRows

  private var isLoading: Bool {
    branchMenu == nil
  }
  @State private var query = ""
  @State private var highlightedIndex = 0
  // Leading index of the rendered window; slides as the highlight crosses an edge so the list never scrolls.
  @State private var windowStart = 0

  // Render a fixed window and paginate the rest to keep the dialog compact.
  private let pageSize = 8

  private var matches: [String] {
    branchMenu?.refs(matching: query) ?? []
  }

  var body: some View {
    // Flatten once per render; the window derivations below all read this local.
    let matches = matches
    let windowEnd = min(windowStart + pageSize, matches.count)
    let visibleMatches = windowStart < matches.count ? Array(matches[windowStart..<windowEnd]) : []
    // Full-width row so the search field fills and the menu reaches the trailing edge.
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(caption)
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        if isLoading {
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
          topRows

          Divider()

          if let branchMenu {
            if !branchMenu.localBranches.isEmpty {
              Menu("Local") {
                ForEach(branchMenu.localBranches) { node in
                  WorktreeBranchNodeMenu(node: node, selectedRef: selectedRef, onSelect: select)
                }
              }
            }
            ForEach(branchMenu.remotes) { remote in
              WorktreeRemoteBranchMenu(remote: remote, selectedRef: selectedRef, onSelect: select)
            }
          } else {
            Text("Loading branches…")
          }
        } label: {
          Text(menuLabel)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        // Cap and pin trailing so a long ref can't crowd the search field yet still grazes the right edge.
        .frame(maxWidth: 160, alignment: .trailing)
        .layoutPriority(1)
        .help(menuLabel)
      }
      // Fill the row so the menu reaches the trailing edge.
      .frame(maxWidth: .infinity)
      if !query.isEmpty {
        WorktreeRefFilterResults(
          remoteNames: remoteNames,
          selectedRef: selectedRef,
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
    onSelect(ref)
    query = ""
  }
}

/// Inline matches under the filter field (#387). A flat row list rather than a
/// popover, so there's no keyboard-focus juggling; the browse Menu still covers
/// "I don't know the name yet".
private struct WorktreeRefFilterResults: View {
  let remoteNames: [String]
  let selectedRef: String?
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
        .appFont(.callout)
        .foregroundStyle(.secondary)
    } else {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(matches.enumerated()), id: \.element) { index, ref in
            WorktreeRefResultRow(
              ref: ref,
              remoteNames: remoteNames,
              isSelected: selectedRef == ref,
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
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
      }
    }
  }
}

private struct WorktreeRefResultRow: View {
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
          .appFont(.caption)
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

/// Non-branch rows atop the base-ref browse menu: the Auto ref and the
/// matching local default branch quick pick.
private struct WorktreeBaseRefTopRows: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>

  var body: some View {
    WorktreeRefMenuItem(
      isSelected: store.selectedBaseRef == nil,
      label: store.automaticBaseRef.isEmpty
        ? Text("Auto")
        : Text("\(store.automaticBaseRef) \(Text("Auto").foregroundStyle(.secondary))")
    ) {
      store.send(.baseRefSelected(nil))
    }
    if let defaultBranch = store.defaultBranch {
      // Tagged "Local" to distinguish it from the remote-tracking Auto ref above.
      WorktreeRefMenuItem(
        isSelected: store.selectedBaseRef == defaultBranch,
        label: Text("\(defaultBranch) \(Text("Local").foregroundStyle(.secondary))")
      ) {
        store.send(.baseRefSelected(defaultBranch))
      }
    }
  }
}

/// Non-branch rows atop the upstream browse menu: Git's automatic tracking and
/// an explicit no-upstream choice.
private struct WorktreeUpstreamTopRows: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>

  var body: some View {
    WorktreeRefMenuItem(
      isSelected: store.selectedUpstream == .automatic,
      label: Text("Auto")
    ) {
      store.send(.upstreamSelected(.automatic))
    }
    WorktreeRefMenuItem(
      isSelected: store.selectedUpstream == .unset,
      label: Text("None")
    ) {
      store.send(.upstreamSelected(.unset))
    }
  }
}

private struct WorktreeRemoteBranchMenu: View {
  let remote: BaseRefBranchMenu.Remote
  let selectedRef: String?
  let onSelect: (String) -> Void

  var body: some View {
    Menu {
      ForEach(remote.branches) { node in
        WorktreeBranchNodeMenu(node: node, selectedRef: selectedRef, onSelect: onSelect)
      }
    } label: {
      Text("\(remote.name) \(Text("Remote").foregroundStyle(.secondary))")
    }
  }
}

private struct WorktreeBranchNodeMenu: View {
  let node: BranchMenuNode
  let selectedRef: String?
  let onSelect: (String) -> Void

  var body: some View {
    if node.children.isEmpty {
      WorktreeBranchNodeMenuItem(node: node, selectedRef: selectedRef, onSelect: onSelect)
    } else {
      Menu(node.name) {
        // A namespace segment that is also a branch (rare) stays selectable;
        // the item renders nothing for a ref-less segment.
        WorktreeBranchNodeMenuItem(node: node, selectedRef: selectedRef, onSelect: onSelect)
        ForEach(node.children) { child in
          WorktreeBranchNodeMenu(node: child, selectedRef: selectedRef, onSelect: onSelect)
        }
      }
    }
  }
}

private struct WorktreeBranchNodeMenuItem: View {
  let node: BranchMenuNode
  let selectedRef: String?
  let onSelect: (String) -> Void

  var body: some View {
    if let ref = node.ref {
      WorktreeRefMenuItem(isSelected: selectedRef == ref, label: Text(node.name)) {
        onSelect(ref)
      }
    }
  }
}

private struct WorktreeRefMenuItem: View {
  let isSelected: Bool
  let label: Text
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      if isSelected {
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
