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
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Shared(.sidebarNestWorktreesByBranch) private var nestWorktreesByBranch: Bool

  var body: some View {
    let isRepositoryRemoving = store.state.isRemovingRepository(repository)
    SidebarItemsDragOverlay(
      repository: repository,
      groups: groups,
      selectedWorktreeIDs: selectedWorktreeIDs,
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
  let selectedWorktreeIDs: Set<Worktree.ID>
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
        selectedWorktreeIDs: selectedWorktreeIDs,
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
  let selectedWorktreeIDs: Set<Worktree.ID>
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
          selectedWorktreeIDs: selectedWorktreeIDs,
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
            selectedWorktreeIDs: selectedWorktreeIDs,
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
            selectedWorktreeIDs: selectedWorktreeIDs,
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
  let selectedWorktreeIDs: Set<Worktree.ID>
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
        selectedWorktreeIDs: selectedWorktreeIDs,
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
          .frame(width: 12)
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
  let selectedWorktreeIDs: Set<Worktree.ID>
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
        selectedWorktreeIDs: selectedWorktreeIDs,
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
  let selectedWorktreeIDs: Set<Worktree.ID>
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
      selectedWorktreeIDs: selectedWorktreeIDs,
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
  let selectedWorktreeIDs: Set<Worktree.ID>
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
      if !terminalState.focusSurface(id: notification.surfaceID) {
        notificationLogger.warning("Failed to focus surface \(notification.surfaceID) for worktree \(rowID).")
      }
    }
    .tag(SidebarSelection.worktree(rowID))
    .id(rowID)
    .typeSelectEquivalent("")
    .moveDisabled(moveDisabled)
    .contextMenu {
      let isRemovable = store.lifecycle == .idle
      if isRemovable, let worktree = parentStore.state.worktree(for: rowID), !isRepositoryRemoving {
        SidebarItemContextMenu(
          worktree: worktree,
          rowID: rowID,
          rowKind: store.kind,
          repositoryID: store.repositoryID,
          store: parentStore,
          selectedWorktreeIDs: selectedWorktreeIDs
        )
      }
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
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager

  var body: some View {
    let isRepositoryRemoving = store.state.isRemovingRepository(repository)
    SidebarItemRow(
      rowID: rowID,
      store: store,
      terminalManager: terminalManager,
      selectedWorktreeIDs: selectedWorktreeIDs,
      isRepositoryRemoving: isRepositoryRemoving,
      hideSubtitle: true,
      moveMode: .alwaysEnabled,
      shortcutHint: shortcutHint
    )
  }
}

private struct SidebarItemContextMenu: View {
  let worktree: Worktree
  let rowID: SidebarItemID
  let rowKind: SidebarItemFeature.State.Kind
  let repositoryID: Repository.ID
  @Bindable var store: StoreOf<RepositoriesFeature>
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Shared(.settingsFile) private var settingsFile

  private var rowIsFolder: Bool { rowKind == .folder }

  private var contextRows: [SidebarItemFeature.State] {
    guard selectedWorktreeIDs.count > 1, selectedWorktreeIDs.contains(rowID) else {
      return store.state.selectedRow(for: rowID).map { [$0] } ?? []
    }
    let rows = selectedWorktreeIDs.compactMap { store.state.selectedRow(for: $0) }
    return rows
  }

  /// Mixed-kind bulk selections surface no menu; per-kind actions don't compose.
  private var hasMixedKindSelection: Bool {
    contextRows.count > 1 && Set(contextRows.map(\.kind)).count > 1
  }

  private var isAllFoldersBulk: Bool {
    contextRows.count > 1 && contextRows.allSatisfy(\.isFolder)
  }

  private var openActionSelection: OpenWorktreeAction {
    @Shared(.repositorySettings(worktree.repositoryRootURL)) var repositorySettings
    return OpenWorktreeAction.fromSettingsID(
      repositorySettings.openActionID,
      defaultEditorID: settingsFile.global.defaultEditorID
    )
  }

  var body: some View {
    if hasMixedKindSelection {
      EmptyView()
    } else {
      menuContents(
        contextRows: contextRows,
        isBulkSelection: contextRows.count > 1,
        overrides: settingsFile.global.shortcutOverrides
      )
    }
  }

  @ViewBuilder
  private func menuContents(
    contextRows: [SidebarItemFeature.State],
    isBulkSelection: Bool,
    overrides: [AppShortcutID: AppShortcutOverride]
  ) -> some View {
    let archiveShortcut = AppShortcuts.archiveWorktree.effective(from: overrides)
    let deleteShortcut = AppShortcuts.deleteWorktree.effective(from: overrides)
    let isAllFoldersBulk = isAllFoldersBulk

    if !isBulkSelection, !worktree.isMissing {
      openActions(overrides: overrides)
      Divider()
    }

    pinActions(contextRows: contextRows, isBulkSelection: isBulkSelection)

    if !isBulkSelection {
      Button("Copy as Pathname", systemImage: "doc.on.doc") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(worktree.workingDirectory.path, forType: .string)
      }
      if !rowIsFolder {
        Button("Copy as Branch Name") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(worktree.name, forType: .string)
        }
      }
      if let singleRow = contextRows.first,
        !rowIsFolder,
        singleRow.lifecycle == .idle,
        !worktree.isMissing,
        worktree.isAttached
      {
        Button("Rename Branch…", systemImage: "pencil") {
          store.send(.requestRenameBranch(worktree.id, repositoryID))
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
        Divider()
      } else if let row = contextRows.first,
        !row.isMainWorktree,
        !row.lifecycle.isPending
      {
        Button("Customize Appearance…", systemImage: "paintbrush") {
          store.send(.requestCustomizeWorktree(rowID, repositoryID))
        }
        .help("Set a custom title or color")
        Divider()
      }
    }

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
    if !deleteTargets.isEmpty {
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
  private func pinActions(contextRows: [SidebarItemFeature.State], isBulkSelection: Bool) -> some View {
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
    let availableActions = OpenWorktreeAction.availableCases.filter { $0 != .finder }
    let resolved = OpenWorktreeAction.availableSelection(openActionSelection)
    let primarySelection = resolved == .finder ? availableActions.first : resolved
    let openShortcut = AppShortcuts.openWorktree.effective(from: overrides)
    let revealShortcut = AppShortcuts.revealInFinder.effective(from: overrides)

    if let primarySelection {
      Button("Open with \(primarySelection.labelTitle)", systemImage: "arrow.up.right.square") {
        store.send(.contextMenuOpenWorktree(worktree.id, primarySelection))
      }
      .appKeyboardShortcut(openShortcut)
      .help("Open with \(primarySelection.labelTitle) (\(openShortcut?.display ?? "none"))")
    }

    Menu("Open With") {
      ForEach(availableActions) { action in
        Button {
          store.send(.contextMenuOpenWorktree(worktree.id, action))
        } label: {
          OpenWorktreeActionMenuLabelView(action: action, shortcutHint: nil)
        }
        .help("Open with \(action.labelTitle)")
      }
    }

    Button("Reveal in Finder", systemImage: "folder") {
      store.send(.contextMenuOpenWorktree(worktree.id, .finder))
    }
    .appKeyboardShortcut(revealShortcut)
    .help("Reveal in Finder (\(revealShortcut?.display ?? "none"))")
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
