import AppKit
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

  private var browseTopRows: [WorktreeRefBrowseTopRow<String?>] {
    var rows = [
      WorktreeRefBrowseTopRow<String?>(
        title: store.automaticBaseRef.isEmpty ? "Auto" : store.automaticBaseRef,
        detail: store.automaticBaseRef.isEmpty ? nil : "Auto",
        selection: nil,
        isSelected: store.selectedBaseRef == nil
      )
    ]
    if let defaultBranch = store.defaultBranch {
      rows.append(
        WorktreeRefBrowseTopRow(
          title: defaultBranch,
          detail: "Local",
          selection: defaultBranch,
          isSelected: store.selectedBaseRef == defaultBranch
        )
      )
    }
    return rows
  }

  var body: some View {
    WorktreeRefPickerField(
      title: "Base ref",
      caption: "The branch or ref the new worktree will be created from.",
      menuLabel: store.baseRefMenuLabel,
      branchMenu: store.branchMenu,
      remoteNames: store.remoteNames,
      selectedRef: store.selectedBaseRef,
      browseTopRows: browseTopRows,
      onSelect: { store.send(.baseRefSelected($0)) },
      onSelectBrowseTopRow: { store.send(.baseRefSelected($0)) }
    )
  }
}

private struct WorktreeUpstreamField: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>

  private var browseTopRows: [WorktreeRefBrowseTopRow<WorktreeUpstreamPreference>] {
    [
      WorktreeRefBrowseTopRow(
        title: "Auto",
        detail: nil,
        selection: .automatic,
        isSelected: store.selectedUpstream == .automatic
      ),
      WorktreeRefBrowseTopRow(
        title: "None",
        detail: nil,
        selection: .unset,
        isSelected: store.selectedUpstream == .unset
      ),
    ]
  }

  var body: some View {
    WorktreeRefPickerField(
      title: "Upstream",
      caption: "The branch the new branch tracks. Auto leaves it to Git, which tracks a remote base ref by default.",
      menuLabel: store.upstreamMenuLabel,
      branchMenu: store.upstreamBranchMenu,
      remoteNames: store.remoteNames,
      selectedRef: store.selectedUpstreamBranch,
      browseTopRows: browseTopRows,
      onSelect: { store.send(.upstreamSelected(.branch($0))) },
      onSelectBrowseTopRow: { store.send(.upstreamSelected($0)) }
    )
  }
}

/// Shared search + browse picker over the branch inventory; the callers inject the
/// non-branch top rows (Auto / None / quick picks) and their selection action.
private struct WorktreeRefPickerField<TopSelection: Hashable>: View {
  let title: String
  let caption: String
  let menuLabel: String
  let branchMenu: BaseRefBranchMenu?
  let remoteNames: [String]
  let selectedRef: String?
  let browseTopRows: [WorktreeRefBrowseTopRow<TopSelection>]
  let onSelect: (String) -> Void
  let onSelectBrowseTopRow: (TopSelection) -> Void

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
          .font(.caption)
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
        WorktreeRefBrowseMenu(
          menuLabel: menuLabel,
          branchMenu: branchMenu,
          selectedRef: selectedRef,
          topRows: browseTopRows,
          onSelectBranch: select,
          onSelectTopRow: selectBrowseTopRow
        )
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

  private func selectBrowseTopRow(_ selection: TopSelection) {
    onSelectBrowseTopRow(selection)
    query = ""
  }
}

private struct WorktreeRefBrowseTopRow<Selection: Hashable>: Hashable {
  let title: String
  let detail: String?
  let selection: Selection
  let isSelected: Bool
}

/// Owns the AppKit menu so unrelated SwiftUI updates cannot replace an open submenu.
private struct WorktreeRefBrowseMenu<TopSelection: Hashable>: NSViewRepresentable {
  let menuLabel: String
  let branchMenu: BaseRefBranchMenu?
  let selectedRef: String?
  let topRows: [WorktreeRefBrowseTopRow<TopSelection>]
  let onSelectBranch: (String) -> Void
  let onSelectTopRow: (TopSelection) -> Void

  struct Snapshot: Equatable {
    let menuLabel: String
    let branchMenu: BaseRefBranchMenu?
    let selectedRef: String?
    let topRows: [WorktreeRefBrowseTopRow<TopSelection>]
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: true)
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
  }

  func updateNSView(_ button: NSPopUpButton, context: Context) {
    context.coordinator.update(
      button,
      snapshot: Snapshot(
        menuLabel: menuLabel,
        branchMenu: branchMenu,
        selectedRef: selectedRef,
        topRows: topRows
      ),
      onSelectBranch: onSelectBranch,
      onSelectTopRow: onSelectTopRow
    )
  }

  final class Coordinator: NSObject {
    private var snapshot: Snapshot?
    private var topRows: [WorktreeRefBrowseTopRow<TopSelection>] = []
    private var onSelectBranch: (String) -> Void = { _ in }
    private var onSelectTopRow: (TopSelection) -> Void = { _ in }

    func update(
      _ button: NSPopUpButton,
      snapshot: Snapshot,
      onSelectBranch: @escaping (String) -> Void,
      onSelectTopRow: @escaping (TopSelection) -> Void
    ) {
      self.topRows = snapshot.topRows
      self.onSelectBranch = onSelectBranch
      self.onSelectTopRow = onSelectTopRow
      button.toolTip = snapshot.menuLabel
      button.setAccessibilityLabel(snapshot.menuLabel)

      guard snapshot != self.snapshot else { return }
      button.menu = makeMenu(for: snapshot)
      self.snapshot = snapshot
    }

    private func makeMenu(for snapshot: Snapshot) -> NSMenu {
      let menu = NSMenu()
      menu.autoenablesItems = false
      menu.addItem(NSMenuItem(title: snapshot.menuLabel, action: nil, keyEquivalent: ""))

      for (index, row) in snapshot.topRows.enumerated() {
        let item = NSMenuItem(
          title: row.title,
          action: #selector(selectTopRow(_:)),
          keyEquivalent: ""
        )
        item.attributedTitle = attributedTitle(row.title, detail: row.detail)
        item.state = row.isSelected ? .on : .off
        item.target = self
        item.tag = index
        menu.addItem(item)
      }

      menu.addItem(.separator())
      guard let branchMenu = snapshot.branchMenu else {
        let loadingItem = NSMenuItem(title: "Loading branches…", action: nil, keyEquivalent: "")
        loadingItem.isEnabled = false
        menu.addItem(loadingItem)
        return menu
      }

      if !branchMenu.localBranches.isEmpty {
        let localItem = NSMenuItem(title: "Local", action: nil, keyEquivalent: "")
        let localMenu = NSMenu()
        for node in branchMenu.localBranches {
          if let item = branchItem(for: node, selectedRef: snapshot.selectedRef) {
            localMenu.addItem(item)
          }
        }
        localItem.submenu = localMenu
        menu.addItem(localItem)
      }

      for remote in branchMenu.remotes {
        let remoteItem = NSMenuItem(title: remote.name, action: nil, keyEquivalent: "")
        remoteItem.attributedTitle = attributedTitle(remote.name, detail: "Remote")
        let remoteMenu = NSMenu()
        for node in remote.branches {
          if let item = branchItem(for: node, selectedRef: snapshot.selectedRef) {
            remoteMenu.addItem(item)
          }
        }
        remoteItem.submenu = remoteMenu
        menu.addItem(remoteItem)
      }
      return menu
    }

    private func branchItem(for node: BranchMenuNode, selectedRef: String?) -> NSMenuItem? {
      guard !node.children.isEmpty else {
        guard let ref = node.ref else { return nil }
        return branchLeaf(title: node.name, ref: ref, selectedRef: selectedRef)
      }

      let item = NSMenuItem(title: node.name, action: nil, keyEquivalent: "")
      let submenu = NSMenu()
      if let ref = node.ref {
        submenu.addItem(branchLeaf(title: node.name, ref: ref, selectedRef: selectedRef))
      }
      for child in node.children {
        if let childItem = branchItem(for: child, selectedRef: selectedRef) {
          submenu.addItem(childItem)
        }
      }
      item.submenu = submenu
      return item
    }

    private func branchLeaf(title: String, ref: String, selectedRef: String?) -> NSMenuItem {
      let item = NSMenuItem(
        title: title,
        action: #selector(selectBranch(_:)),
        keyEquivalent: ""
      )
      item.state = selectedRef == ref ? .on : .off
      item.target = self
      item.representedObject = ref
      return item
    }

    private func attributedTitle(_ title: String, detail: String?) -> NSAttributedString {
      let attributedTitle = NSMutableAttributedString(string: title)
      if let detail {
        attributedTitle.append(
          NSAttributedString(
            string: " \(detail)",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
          )
        )
      }
      return attributedTitle
    }

    @objc private func selectBranch(_ sender: NSMenuItem) {
      guard let ref = sender.representedObject as? String else { return }
      onSelectBranch(ref)
    }

    @objc private func selectTopRow(_ sender: NSMenuItem) {
      guard topRows.indices.contains(sender.tag) else { return }
      onSelectTopRow(topRows[sender.tag].selection)
    }
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
        .font(.callout)
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
            .font(.caption)
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
