import AppKit
import ComposableArchitecture
import OrderedCollections
import Sharing
import SupacodeSettingsShared
import SwiftUI

private nonisolated let notificationLogger = SupaLogger("Notifications")

struct SidebarItemsView: View {
  let repository: Repository
  /// Precomputed per-repo slot layout from `SidebarStructure`. The view does
  /// no slot derivation: it walks `groups` in order and renders.
  let groups: [SidebarItemGroup]
  /// Already-resolved shortcut hint strings from the structure's `slotByID`
  /// joined with `commandKeyObserver.isPressed` + shortcut overrides at the
  /// `SidebarListView` level. `nil` here means "no hint to render".
  let shortcutHintByID: [Worktree.ID: String]
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Shared(.sidebarNestWorktreesByBranch) private var nestWorktreesByBranch: Bool

  var body: some View {
    let isRepositoryRemoving = store.state.isRemovingRepository(repository)
    SidebarItemsDragOverlay(
      repository: repository,
      groups: groups,
      store: store,
      terminalManager: terminalManager,
      isRepositoryRemoving: isRepositoryRemoving,
      shortcutHintByID: shortcutHintByID,
      nestWorktreesByBranch: nestWorktreesByBranch && repository.isGitRepository
    )
  }
}

/// Drag highlights now live on each `SidebarItemFeature.State.isDragging`; the
/// overlay struct is kept for code locality but holds no state of its own.
private struct SidebarItemsDragOverlay: View {
  let repository: Repository
  let groups: [SidebarItemGroup]
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let isRepositoryRemoving: Bool
  let shortcutHintByID: [Worktree.ID: String]
  let nestWorktreesByBranch: Bool

  var body: some View {
    ForEach(groups) { group in
      SidebarItemGroupView(
        repository: repository,
        rowIDs: group.rowIDs,
        store: store,
        terminalManager: terminalManager,
        isRepositoryRemoving: isRepositoryRemoving,
        hideSubtitle: group.hideSubtitle,
        moveBehavior: group.moveBehavior,
        shortcutHintByID: shortcutHintByID,
        nestWorktreesByBranch: nestWorktreesByBranch && group.supportsBranchNesting
      )
    }
  }
}

private struct SidebarItemGroupView: View {
  let repository: Repository
  let rowIDs: [SidebarItemID]
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let isRepositoryRemoving: Bool
  let hideSubtitle: Bool
  let moveBehavior: SidebarItemGroup.MoveBehavior
  let shortcutHintByID: [Worktree.ID: String]
  let nestWorktreesByBranch: Bool

  var body: some View {
    let bucketID = moveBehavior.bucketID
    let groupingActive = nestWorktreesByBranch && bucketID != nil
    let nestedBranchRows: [SidebarBranchNesting.Row] =
      if groupingActive, let bucketID {
        SidebarBranchNesting.buildRows(
          itemIDs: rowIDs,
          branchNames: branchNames(for: rowIDs),
          collapsedPrefixes: store.state.sidebar.sections[repository.id]?.buckets[bucketID]?
            .collapsedBranchPrefixes ?? []
        )
      } else {
        rowIDs.map { .leaf(id: $0, depth: 0, displayName: nil) }
      }

    // A no-op `.onMove` still steals the repo-level reorder gesture, so omit it
    // for single-row groups. Grouping suppresses reorder for the entire bucket:
    // cross-group drags would snap back when the tree re-derives from branch
    // names, and the alphabetical sort would clobber any in-bucket reorder.
    let shortcutHintBuilder: (SidebarItemID) -> String? = { rowID in
      shortcutHintByID[rowID]
    }
    switch moveBehavior {
    case .disabled:
      ForEach(nestedBranchRows) { row in
        SidebarBranchNestingRowView(
          repositoryID: repository.id,
          bucketID: moveBehavior.bucketID,
          row: row,
          store: store,
          terminalManager: terminalManager,
          isRepositoryRemoving: isRepositoryRemoving,
          hideSubtitle: hideSubtitle,
          moveMode: .alwaysDisabled,
          shortcutHint: shortcutHintBuilder
        )
      }
    case .pinned, .unpinned:
      if groupingActive {
        ForEach(nestedBranchRows) { row in
          SidebarBranchNestingRowView(
            repositoryID: repository.id,
            bucketID: moveBehavior.bucketID,
            row: row,
            store: store,
            terminalManager: terminalManager,
            isRepositoryRemoving: isRepositoryRemoving,
            hideSubtitle: hideSubtitle,
            moveMode: .alwaysDisabled,
            shortcutHint: shortcutHintBuilder
          )
        }
      } else {
        ForEach(nestedBranchRows) { row in
          SidebarBranchNestingRowView(
            repositoryID: repository.id,
            bucketID: moveBehavior.bucketID,
            row: row,
            store: store,
            terminalManager: terminalManager,
            isRepositoryRemoving: isRepositoryRemoving,
            hideSubtitle: hideSubtitle,
            moveMode: .conditional,
            shortcutHint: shortcutHintBuilder
          )
        }
        .onMove(perform: moveRows)
      }
    }
  }

  /// Read every row's branchName through a per-leaf scoped child store so
  /// SwiftUI's observation graph is bounded to the leaf's own branchName
  /// rather than tracking the full `sidebarItems` IdentifiedArray. Without
  /// this, every per-row tick (agent storm, notification, running-script
  /// update) would invalidate the parent. See AGENTS.md "Sidebar performance".
  private func branchNames(for ids: [SidebarItemID]) -> [SidebarItemID: String] {
    var result: [SidebarItemID: String] = [:]
    for id in ids {
      guard
        let leafStore = store.scope(
          state: \.sidebarItems[id: id], action: \.sidebarItems[id: id]
        )
      else { continue }
      result[id] = leafStore.state.branchName
    }
    return result
  }

  private func moveRows(_ offsets: IndexSet, _ destination: Int) {
    // `rowIDs` here is the post-hoisting visible list; the full bucket lives
    // on `sidebar.sections`. Translate against the full order so hoisted
    // siblings keep their relative positions across the move.
    let target: (repositoryID: Repository.ID, bucket: SidebarBucket)
    switch moveBehavior {
    case .disabled: return
    case .pinned(let id): target = (id, .pinned)
    case .unpinned(let id): target = (id, .unpinned)
    }
    guard
      let fullKeys = store.state.sidebar.sections[target.repositoryID]?
        .buckets[target.bucket]?.items.keys
    else { return }
    guard
      let translated = SidebarItemGroup.translateFilteredMove(
        offsets: offsets,
        destination: destination,
        visibleIDs: rowIDs,
        fullIDs: Array(fullKeys)
      )
    else { return }
    switch moveBehavior {
    case .disabled: return
    case .pinned(let id):
      store.send(.pinnedWorktreesMoved(repositoryID: id, translated.offsets, translated.destination))
    case .unpinned(let id):
      store.send(.unpinnedWorktreesMoved(repositoryID: id, translated.offsets, translated.destination))
    }
  }
}

extension SidebarItemGroup.MoveBehavior {
  var bucketID: SidebarBucket? {
    switch self {
    case .disabled: nil
    case .pinned: .pinned
    case .unpinned: .unpinned
    }
  }
}

private struct SidebarBranchNestingRowView: View {
  let repositoryID: Repository.ID
  let bucketID: SidebarBucket?
  let row: SidebarBranchNesting.Row
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let isRepositoryRemoving: Bool
  let hideSubtitle: Bool
  let moveMode: SidebarRowMoveMode
  let shortcutHint: (SidebarItemID) -> String?

  var body: some View {
    switch row {
    case .leaf(let id, let depth, let displayName):
      SidebarItemRow(
        rowID: id,
        store: store,
        terminalManager: terminalManager,
        isRepositoryRemoving: isRepositoryRemoving,
        hideSubtitle: hideSubtitle,
        moveMode: moveMode,
        shortcutHint: shortcutHint(id),
        displayNameOverride: displayName,
        nestDepth: depth
      )
    case .groupHeader(let prefix, let components, let depth, let isCollapsed, let leafDescendantIDs):
      if let bucketID {
        SidebarPathGroupHeaderRow(
          repositoryID: repositoryID,
          bucketID: bucketID,
          prefix: prefix,
          components: components,
          depth: depth,
          isCollapsed: isCollapsed,
          leafDescendantIDs: leafDescendantIDs,
          store: store
        )
      }
    }
  }
}

/// Header row for a nested branch group. Holds only value-type inputs so a
/// per-row state mutation in the bucket (e.g. an agent tool storm on one
/// leaf) doesn't invalidate this row; the per-leaf indicator aggregation is
/// scoped to its own subview that observes only its descendants.
private struct SidebarPathGroupHeaderRow: View {
  let repositoryID: Repository.ID
  let bucketID: SidebarBucket
  let prefix: String
  let components: [String]
  let depth: Int
  let isCollapsed: Bool
  let leafDescendantIDs: [SidebarItemID]
  @Bindable var store: StoreOf<RepositoriesFeature>

  var body: some View {
    let label = components.isEmpty ? prefix : components.joined(separator: "/")
    Button {
      _ = withAnimation(.easeOut(duration: 0.2)) {
        store.send(
          .branchNestExpansionChanged(
            repositoryID: repositoryID,
            bucketID: bucketID,
            prefix: prefix,
            isExpanded: isCollapsed
          )
        )
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isCollapsed ? 0 : 90))
          .animation(.easeInOut(duration: 0.15), value: isCollapsed)
          .frame(width: SidebarNestLayout.groupChevronWidth)
          .padding(
            .trailing, SidebarNestLayout.leadingSlotWidth - SidebarNestLayout.groupChevronWidth
          )
          .accessibilityHidden(true)
        Text(label)
          .font(.body)
          .lineLimit(1)
          .foregroundStyle(.primary)
        Spacer(minLength: 0)
        if isCollapsed {
          SidebarPathGroupAggregatedIndicators(parentStore: store, leafIDs: leafDescendantIDs)
        }
      }
      .contentShape(.interaction, .rect)
    }
    .buttonStyle(.plain)
    .listRowInsets(.leading, CGFloat(depth) * SidebarNestLayout.indentStep)
    .listRowInsets(.vertical, 6)
    .moveDisabled(true)
    .help(isCollapsed ? "Expand \(label)" : "Collapse \(label)")
    .accessibilityLabel("\(label) group, \(isCollapsed ? "collapsed" : "expanded")")
  }
}

/// Aggregates per-leaf indicators (notification, running scripts, agents)
/// by scoping each descendant through `store.scope(state: \.sidebarItems[id:])`.
/// Per-leaf scoping keeps observation bounded to each leaf's own state, so a
/// tool storm on one row only invalidates this view (not the surrounding row
/// chrome). Aggregation itself delegates to the tested pure function in
/// `SidebarBranchNesting` so there is one algorithm and one set of tests.
private struct SidebarPathGroupAggregatedIndicators: View {
  @Bindable var parentStore: StoreOf<RepositoriesFeature>
  let leafIDs: [SidebarItemID]

  var body: some View {
    SidebarPathGroupIndicatorsView(indicators: SidebarBranchNesting.aggregateIndicators(from: snapshots))
      .equatable()
  }

  private var snapshots: [SidebarBranchNesting.LeafIndicatorSnapshot] {
    leafIDs.compactMap { id in
      guard
        let leafStore = parentStore.scope(
          state: \.sidebarItems[id: id], action: \.sidebarItems[id: id]
        )
      else { return nil }
      return SidebarBranchNesting.LeafIndicatorSnapshot(
        hasUnseenNotifications: leafStore.state.hasUnseenNotifications,
        runningScriptColors: leafStore.state.runningScripts.map(\.tint),
        agents: leafStore.state.agents
      )
    }
  }
}

private struct SidebarPathGroupIndicatorsView: View, Equatable {
  let indicators: SidebarBranchNesting.GroupIndicators

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.indicators == rhs.indicators
  }

  var body: some View {
    if !indicators.isEmpty {
      HStack(spacing: 6) {
        if !indicators.agents.isEmpty {
          AgentAvatarGroupView(instances: indicators.agents, size: 16)
        }
        if !indicators.runningScriptColors.isEmpty || indicators.hasNotification {
          SidebarPathGroupStatusDotView(
            runningScriptColors: indicators.runningScriptColors,
            hasNotification: indicators.hasNotification
          )
        }
      }
      .transition(.blurReplace)
    }
  }
}

private struct SidebarPathGroupStatusDotView: View, Equatable {
  let runningScriptColors: [RepositoryColor]
  let hasNotification: Bool
  @Environment(\.backgroundProminence) private var backgroundProminence

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.runningScriptColors == rhs.runningScriptColors
      && lhs.hasNotification == rhs.hasNotification
  }

  var body: some View {
    let isRunning = !runningScriptColors.isEmpty
    ZStack {
      if isRunning {
        SidebarPingMultiColorDot(
          colors: runningScriptColors,
          isEmphasized: backgroundProminence == .increased,
          size: 6,
          showsSolidCenter: !hasNotification
        )
      }
      if hasNotification {
        Circle()
          .fill(.orange)
          .frame(width: 6, height: 6)
          .accessibilityLabel("Unread notifications in group")
      }
    }
  }
}

enum SidebarRowMoveMode {
  case alwaysDisabled
  case alwaysEnabled
  case conditional
}

struct SidebarItemRow: View {
  let rowID: SidebarItemID
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let isRepositoryRemoving: Bool
  let hideSubtitle: Bool
  let moveMode: SidebarRowMoveMode
  let shortcutHint: String?
  var displayNameOverride: String?
  var nestDepth: Int = 0
  /// Non-nil while the row is rendered inside the global Pinned / Active
  /// sections; injected as a `repo · worktree` subtitle disambiguator.
  var highlightSubtitle: SidebarHighlightRepoTag?

  var body: some View {
    if let itemStore = store.scope(state: \.sidebarItems[id: rowID], action: \.sidebarItems[id: rowID]) {
      SidebarItemContainer(
        store: itemStore,
        parentStore: store,
        terminalManager: terminalManager,
        isRepositoryRemoving: isRepositoryRemoving,
        hideSubtitle: hideSubtitle,
        moveMode: moveMode,
        shortcutHint: shortcutHint,
        displayNameOverride: displayNameOverride,
        nestDepth: nestDepth,
        highlightSubtitle: highlightSubtitle
      )
    }
  }
}

private struct SidebarItemContainer: View {
  let store: StoreOf<SidebarItemFeature>
  @Bindable var parentStore: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let isRepositoryRemoving: Bool
  let hideSubtitle: Bool
  let moveMode: SidebarRowMoveMode
  let shortcutHint: String?
  var displayNameOverride: String?
  var nestDepth: Int = 0
  var highlightSubtitle: SidebarHighlightRepoTag?
  @Shared(.appStorage("worktreeRowHideSubtitleOnMatch")) private var hideSubtitleOnMatch = true

  var body: some View {
    SidebarItemBody(
      store: store,
      parentStore: parentStore,
      terminalManager: terminalManager,
      isRepositoryRemoving: isRepositoryRemoving,
      hideSubtitle: hideSubtitle,
      moveMode: moveMode,
      shortcutHint: shortcutHint,
      displayNameOverride: displayNameOverride,
      nestDepth: nestDepth,
      highlightSubtitle: highlightSubtitle,
      hideSubtitleOnMatch: hideSubtitleOnMatch
    )
  }
}

private struct SidebarItemBody: View {
  let store: StoreOf<SidebarItemFeature>
  @Bindable var parentStore: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let isRepositoryRemoving: Bool
  let hideSubtitle: Bool
  let moveMode: SidebarRowMoveMode
  let shortcutHint: String?
  let displayNameOverride: String?
  let nestDepth: Int
  let highlightSubtitle: SidebarHighlightRepoTag?
  let hideSubtitleOnMatch: Bool

  var body: some View {
    let rowID = store.state.id
    let lifecycle = store.lifecycle
    let isDragging = store.isDragging
    let moveDisabled: Bool =
      switch moveMode {
      case .alwaysDisabled: true
      case .alwaysEnabled: false
      case .conditional: isRepositoryRemoving || lifecycle.isTerminating
      }
    SidebarItemView(
      store: store,
      hideSubtitle: hideSubtitle,
      hideSubtitleOnMatch: hideSubtitleOnMatch,
      showsPullRequestInfo: !isDragging,
      shortcutHint: shortcutHint,
      displayNameOverride: displayNameOverride,
      nestDepth: nestDepth,
      highlightSubtitle: highlightSubtitle
    )
    .environment(\.focusNotificationAction) { notification in
      guard let terminalState = terminalManager.stateIfExists(for: rowID) else {
        notificationLogger.warning(
          "No terminal state for worktree \(rowID) when focusing notification \(notification.surfaceID).")
        return
      }
      // Without selecting the row first the jump lands in an off-screen worktree,
      // marking the notification read on a pane the user never sees.
      parentStore.send(.selectWorktree(rowID, focusTerminal: true))
      if !terminalState.focusSurface(id: notification.surfaceID) {
        notificationLogger.warning("Failed to focus surface \(notification.surfaceID) for worktree \(rowID).")
      }
    }
    .tag(SidebarSelection.worktree(rowID))
    .id(rowID)
    .typeSelectEquivalent("")
    .moveDisabled(moveDisabled)
    .contextMenu {
      // Every field the menu branches on lives on the leaf, so the row body never
      // resolves a `Worktree` from the parent (which would observation-track the
      // whole repository roster from every row).
      SidebarItemContextMenu(
        row: SidebarContextRow(store.state),
        isRepositoryRemoving: isRepositoryRemoving,
        store: parentStore
      )
    }
    .disabled(isRepositoryRemoving && store.lifecycle != .idle)
    .contentShape(.dragPreview, .rect)
    .contentShape(.interaction, .rect)
    .onDragSessionUpdated { session in
      let draggedIDs = Set(session.draggedItemIDs(for: Worktree.ID.self))
      let active: Bool
      switch session.phase {
      case .ended, .dataTransferCompleted:
        active = false
      default:
        active = draggedIDs.contains(rowID)
      }
      if active != store.isDragging {
        store.send(.dragSessionChanged(isDragging: active))
      }
    }
  }
}

/// Folder repos render one row that must be a direct child of the outer
/// `.onMove` to receive repo-level drags. The structure pre-resolves the
/// synthetic worktree id and the shortcut hint; the view does no lookup.
struct SidebarFolderRow: View {
  let repository: Repository
  let rowID: Worktree.ID
  let shortcutHint: String?
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager

  var body: some View {
    let isRepositoryRemoving = store.state.isRemovingRepository(repository)
    SidebarItemRow(
      rowID: rowID,
      store: store,
      terminalManager: terminalManager,
      isRepositoryRemoving: isRepositoryRemoving,
      hideSubtitle: true,
      moveMode: .alwaysEnabled,
      shortcutHint: shortcutHint
    )
  }
}

/// The one action that always applies, so a right-click is never a dead click.
private struct SidebarCopyPathnameButton: View {
  let path: String

  var body: some View {
    Button("Copy as Pathname", systemImage: "doc.on.doc") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(path, forType: .string)
    }
  }
}

private struct SidebarItemContextMenu: View {
  /// The right-clicked row, projected from its own leaf store. Sole input: the
  /// menu resolves nothing from the parent's repository roster.
  let row: SidebarContextRow
  let isRepositoryRemoving: Bool
  @Bindable var store: StoreOf<RepositoriesFeature>
  @Shared(.settingsFile) private var settingsFile

  private var rowID: SidebarItemID { row.id }
  private var repositoryID: Repository.ID { row.repositoryID }
  private var rowIsFolder: Bool { row.isFolder }

  /// A terminating row, or one whose repository is being removed, has nothing
  /// left to act on beyond copying its path.
  private var isActionable: Bool { row.lifecycle == .idle && !isRepositoryRemoving }

  /// Resolved off the main actor by `.resolveOpenActions`: the repository-settings
  /// shared key caches its reference weakly, so reading it from here would re-run
  /// the key's disk load on every menu build. The fallback covers the window before
  /// the first resolution lands, and only ever offers an installed editor.
  private var openActionSelection: OpenWorktreeAction {
    store.openActionByRepositoryID[repositoryID]
      ?? OpenWorktreeAction.unresolvedDefault(
        defaultEditorID: settingsFile.global.defaultEditorID,
        installed: store.installedOpenActions
      )
  }

  var body: some View {
    // Reducer-cached: resolving the selected rows here would read
    // `sidebarItems[id:]` per row and observation-track the whole List.
    let slice = store.sidebarSelectionSlice
    let contextRows = slice.contextRows(rightClicked: row)
    let isBulkSelection = contextRows.count > 1
    if !isActionable {
      SidebarCopyPathnameButton(path: row.workingDirectoryPath)
    } else if isBulkSelection, slice.hasMixedKindSelection {
      // Folder and worktree actions don't compose, so the selection has none in
      // common; say so instead of putting up an empty menu.
      Button("No Actions for Mixed Selection") {}
        .disabled(true)
        .help("Folders and worktrees share no actions. Select one kind at a time.")
    } else {
      menuContents(
        contextRows: contextRows,
        isBulkSelection: isBulkSelection,
        isAllFoldersBulk: isBulkSelection && slice.isAllFoldersBulk,
        overrides: settingsFile.global.shortcutOverrides
      )
    }
  }

  @ViewBuilder
  private func menuContents(
    contextRows: [SidebarContextRow],
    isBulkSelection: Bool,
    isAllFoldersBulk: Bool,
    overrides: [AppShortcutID: AppShortcutOverride]
  ) -> some View {
    let archiveShortcut = AppShortcuts.archiveWorktree.effective(from: overrides)
    let deleteShortcut = AppShortcuts.deleteWorktree.effective(from: overrides)

    // Open actions stay shown for a remote row but `openActions` gates each
    // editor per-item via `canOpen` (Reveal in Finder is local-only), so no
    // blanket disable here.
    if !isBulkSelection, !row.isMissing {
      openActions(overrides: overrides)
      Divider()
    }

    pinActions(contextRows: contextRows, isBulkSelection: isBulkSelection)

    if !isBulkSelection {
      SidebarCopyPathnameButton(path: row.workingDirectoryPath)
      if !rowIsFolder {
        Button("Copy as Branch Name") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(row.name, forType: .string)
        }
      }
      if !rowIsFolder, !row.isMissing, row.isAttached {
        Button("Rename Branch…", systemImage: "pencil") {
          store.send(.requestRenameBranch(rowID, repositoryID))
        }
        .help("Rename the local branch for this worktree")
      }
      Divider()
      if rowIsFolder {
        // Folder rows render through SidebarItemRow, which reads customization from the per-row
        // bucket Item. Route through the same worktree path so the folder row picks up the title
        // / color the user picks (section.title would only tint a folder-section header, but
        // folder sections render with an empty header).
        Button("Customize Appearance…", systemImage: "paintbrush") {
          store.send(.requestCustomizeWorktree(rowID, repositoryID))
        }
        .help("Set a custom title or color")
        // Folder rows have no section ellipsis menu, so Settings lives here.
        Button("Folder Settings…", systemImage: "gear") {
          store.send(.openRepositorySettings(repositoryID))
        }
        .help("Open folder settings")
        // Remote folders have no section header either, so the connection editor
        // (offered on a git remote's section menu) lives here for them.
        if row.host != nil {
          Button("Edit Connection…", systemImage: "wifi") {
            store.send(.requestEditRemoteRepository(repositoryID))
          }
          .help("Edit the SSH server, port, user, or path")
        }
        Divider()
      } else if let singleRow = contextRows.first,
        !singleRow.isMainWorktree,
        !singleRow.lifecycle.isPending
      {
        Button("Customize Appearance…", systemImage: "paintbrush") {
          store.send(.requestCustomizeWorktree(rowID, repositoryID))
        }
        .help("Set a custom title or color")
        Divider()
      }
    }

    archiveAndDeleteActions(
      contextRows: contextRows,
      isBulkSelection: isBulkSelection,
      isAllFoldersBulk: isAllFoldersBulk,
      archiveShortcut: archiveShortcut,
      deleteShortcut: deleteShortcut
    )
  }

  @ViewBuilder
  private func archiveAndDeleteActions(
    contextRows: [SidebarContextRow],
    isBulkSelection: Bool,
    isAllFoldersBulk: Bool,
    archiveShortcut: AppShortcut?,
    deleteShortcut: AppShortcut?
  ) -> some View {
    let archiveTargets =
      contextRows
      .filter { !$0.isMainWorktree && $0.lifecycle == .idle }
      .map {
        RepositoriesFeature.ArchiveWorktreeTarget(
          worktreeID: $0.id,
          repositoryID: $0.repositoryID
        )
      }
    let deleteTargets = contextRows.map {
      RepositoriesFeature.DeleteWorktreeTarget(
        worktreeID: $0.id,
        repositoryID: $0.repositoryID
      )
    }

    if !archiveTargets.isEmpty {
      let archiveLabel = isBulkSelection ? "Archive Worktrees…" : "Archive Worktree…"
      Button(archiveLabel, systemImage: "archivebox") {
        if archiveTargets.count == 1, let target = archiveTargets.first {
          store.send(.requestArchiveWorktree(target.worktreeID, target.repositoryID))
        } else {
          store.send(.requestArchiveWorktrees(archiveTargets))
        }
      }
      .appKeyboardShortcut(archiveShortcut)
    }
    if !isBulkSelection, rowIsFolder, row.host != nil {
      // A remote folder is the remote repository; its row has no section header,
      // so removal lives here and must drop the config (the local delete
      // pipeline only prunes local roots and would leave the config to reappear).
      Button("Remove Remote Repository…", systemImage: "trash", role: .destructive) {
        store.send(.requestDeleteRepository(repositoryID))
      }
      .help("Remove this remote repository (remote files are untouched)")
      .appKeyboardShortcut(deleteShortcut)
    } else if !deleteTargets.isEmpty {
      let deleteLabel =
        isBulkSelection
        ? (isAllFoldersBulk ? "Remove Folders…" : "Delete Worktrees…")
        : (rowIsFolder ? "Remove Folder…" : "Delete Worktree…")
      Button(deleteLabel, systemImage: "trash", role: .destructive) {
        store.send(.requestDeleteSidebarItems(deleteTargets))
      }
      .appKeyboardShortcut(deleteShortcut)
    }
  }

  @ViewBuilder
  private func pinActions(contextRows: [SidebarContextRow], isBulkSelection: Bool) -> some View {
    // Folder synthetic rows pass `isMainWorktree` by geometry but are pinnable; git "main" still
    // aren't. Pending rows can't pin (reducer would no-op on the unresolved ID).
    let pinnableRows = contextRows.filter {
      (!$0.isMainWorktree || $0.isFolder) && !$0.lifecycle.isPending
    }
    if !pinnableRows.isEmpty {
      let allPinned = pinnableRows.allSatisfy(\.isPinned)
      let allFolders = pinnableRows.allSatisfy(\.isFolder)
      // Folder-only selection reads "Pin Folder" / "Pin Folders"; mixed or
      // git-only fall back to "Worktree" so the label stays accurate.
      let noun = allFolders ? "Folder" : "Worktree"
      if allPinned {
        let label = isBulkSelection ? "Unpin \(noun)s" : "Unpin \(noun)"
        Button(label, systemImage: "pin.slash") {
          for pinnableRow in pinnableRows {
            togglePin(for: pinnableRow.id, isPinned: true)
          }
        }
      } else {
        let label = isBulkSelection ? "Pin \(noun)s" : "Pin \(noun)"
        Button(label, systemImage: "pin") {
          for pinnableRow in pinnableRows where !pinnableRow.isPinned {
            togglePin(for: pinnableRow.id, isPinned: false)
          }
        }
      }
      Divider()
    }
  }

  @ViewBuilder
  private func openActions(overrides: [AppShortcutID: AppShortcutOverride]) -> some View {
    let installed = store.installedOpenActions
    let availableActions = installed.filter { $0 != .finder }
    let resolved = OpenWorktreeAction.availableSelection(openActionSelection, installed: installed)
    let primarySelection = resolved == .finder ? availableActions.first : resolved
    let openShortcut = AppShortcuts.openWorktree.effective(from: overrides)
    let revealShortcut = AppShortcuts.revealInFinder.effective(from: overrides)

    if let primarySelection {
      Button("Open with \(primarySelection.labelTitle)", systemImage: "arrow.up.right.square") {
        store.send(.contextMenuOpenWorktree(rowID, primarySelection))
      }
      .appKeyboardShortcut(openShortcut)
      .help("Open with \(primarySelection.labelTitle) (\(openShortcut?.display ?? "none"))")
      .disabled(!canOpen(primarySelection))
    }

    Menu("Open With") {
      ForEach(availableActions) { action in
        Button {
          store.send(.contextMenuOpenWorktree(rowID, action))
        } label: {
          OpenWorktreeActionMenuLabelView(action: action)
        }
        .help(openActionHelp(for: action))
        .disabled(!canOpen(action))
      }
    }

    Button("Reveal in Finder", systemImage: "folder") {
      store.send(.contextMenuOpenWorktree(rowID, .finder))
    }
    .appKeyboardShortcut(revealShortcut)
    .help("Reveal in Finder (\(revealShortcut?.display ?? "none"))")
    .disabled(row.host != nil)
  }

  /// Whether `action` can open this row: local opens everywhere, remote only
  /// via an editor whose Remote-SSH CLI can express the host.
  private func canOpen(_ action: OpenWorktreeAction) -> Bool {
    guard let host = row.host else { return true }
    return action.remoteOpenInvocation(host: host, remotePath: row.workingDirectoryPath) != nil
  }

  /// Tooltip for an "Open With" entry. A disabled VS Code family row on a
  /// non-default-port host explains the `~/.ssh/config` requirement; otherwise
  /// falls back to the plain action label.
  private func openActionHelp(for action: OpenWorktreeAction) -> String {
    if let host = row.host,
      let reason = action.remoteOpenDisabledReason(host: host, remotePath: row.workingDirectoryPath)
    {
      return reason
    }
    return "Open with \(action.labelTitle)"
  }

  private func togglePin(for worktreeID: Worktree.ID, isPinned: Bool) {
    _ = withAnimation(.easeOut(duration: 0.2)) {
      if isPinned {
        store.send(.unpinWorktree(worktreeID))
      } else {
        store.send(.pinWorktree(worktreeID))
      }
    }
  }
}
