import AppKit
import ComposableArchitecture
import OrderedCollections
import Sharing
import SupacodeSettingsShared
import SwiftUI

private nonisolated let notificationLogger = SupaLogger("Notifications")

struct SidebarItemsView: View {
  let repository: Repository
  let hotkeyIDs: [Worktree.ID]
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Shared(.sidebarNestWorktreesByBranch) private var nestWorktreesByBranch: Bool

  var body: some View {
    let groups = SidebarItemGroup.slots(in: store.state, repositoryID: repository.id)
    let isRepositoryRemoving = store.state.isRemovingRepository(repository)
    let showShortcutHints = commandKeyObserver.isPressed
    let shortcutIndexByID: [Worktree.ID: Int] =
      showShortcutHints ? SidebarShortcutIndex.build(from: hotkeyIDs) : [:]

    SidebarItemsDragOverlay(
      repository: repository,
      groups: groups,
      selectedWorktreeIDs: selectedWorktreeIDs,
      store: store,
      terminalManager: terminalManager,
      isRepositoryRemoving: isRepositoryRemoving,
      shortcutIndexByID: shortcutIndexByID,
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
  let shortcutIndexByID: [Worktree.ID: Int]
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
        shortcutIndexByID: shortcutIndexByID,
        nestWorktreesByBranch: nestWorktreesByBranch && group.supportsBranchNesting
      )
    }
  }
}

struct SidebarItemGroup: Identifiable {
  enum MoveBehavior: Hashable {
    case disabled
    case pinned(Repository.ID)
    case unpinned(Repository.ID)
  }

  enum Slot: Hashable {
    case main(isSole: Bool)
    case pinnedTail
    case pending
    case unpinnedTail
  }

  let slot: Slot
  let repositoryID: Repository.ID
  let rowIDs: [SidebarItemID]

  var id: Slot { slot }

  var hideSubtitle: Bool {
    if case .main(let isSole) = slot { isSole } else { false }
  }

  var moveBehavior: MoveBehavior {
    switch slot {
    case .main, .pending: .disabled
    case .pinnedTail: .pinned(repositoryID)
    case .unpinnedTail: .unpinned(repositoryID)
    }
  }

  /// Only the pinned and unpinned tails participate in branch nesting.
  /// The main and pending slots are structural and shouldn't be folded into a tree.
  var supportsBranchNesting: Bool {
    switch slot {
    case .pinnedTail, .unpinnedTail: true
    case .main, .pending: false
    }
  }
}

extension SidebarItemGroup {
  /// Split one repo's bucketed item IDs into the four ordered slots the
  /// sidebar renders (`main`, `pinnedTail`, `pending`, `unpinnedTail`).
  /// Static rather than top-level per the AGENTS.md "no free functions"
  /// rule. The reducer's `orderedSidebarItemIDs` mirrors this partition
  /// so hotkeys / arrow-nav agree with the visible row order.
  static func slots(
    in state: RepositoriesFeature.State,
    repositoryID: Repository.ID
  ) -> [SidebarItemGroup] {
    guard let bucket = state.sidebarGrouping.bucketsByRepository[repositoryID] else { return [] }
    let pinnedRows = bucket[.pinned]
    let unpinnedRows = bucket[.unpinned]
    let pendingIDs = Set(state.pendingWorktrees.filter { $0.repositoryID == repositoryID }.map(\.id))

    let mainID: SidebarItemID? = pinnedRows.first.flatMap {
      state.sidebarItems[id: $0]?.isMainWorktree == true ? $0 : nil
    }
    let pinnedTail = pinnedRows.filter { $0 != mainID }
    let pendingTail = unpinnedRows.filter { pendingIDs.contains($0) }
    let unpinnedTail = unpinnedRows.filter { !pendingIDs.contains($0) }
    let isSoleDefaultWorktree =
      mainID != nil && pinnedTail.isEmpty && pendingTail.isEmpty && unpinnedTail.isEmpty

    return [
      SidebarItemGroup(
        slot: .main(isSole: isSoleDefaultWorktree),
        repositoryID: repositoryID,
        rowIDs: mainID.map { [$0] } ?? []
      ),
      SidebarItemGroup(slot: .pinnedTail, repositoryID: repositoryID, rowIDs: pinnedTail),
      SidebarItemGroup(slot: .pending, repositoryID: repositoryID, rowIDs: pendingTail),
      SidebarItemGroup(slot: .unpinnedTail, repositoryID: repositoryID, rowIDs: unpinnedTail),
    ]
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
  let shortcutIndexByID: [Worktree.ID: Int]
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
      shortcutHint(for: shortcutIndexByID[rowID])
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

  @Shared(.settingsFile) private var settingsFile

  private func shortcutHint(for index: Int?) -> String? {
    guard let index else { return nil }
    return AppShortcuts.worktreeSelectionShortcutDisplay(
      atSlot: index,
      overrides: settingsFile.global.shortcutOverrides
    )
  }

  private func moveRows(_ offsets: IndexSet, _ destination: Int) {
    switch moveBehavior {
    case .disabled: break
    case .pinned(let repositoryID):
      store.send(.pinnedWorktreesMoved(repositoryID: repositoryID, offsets, destination))
    case .unpinned(let repositoryID):
      store.send(.unpinnedWorktreesMoved(repositoryID: repositoryID, offsets, destination))
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

private struct SidebarItemRow: View {
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
        nestDepth: nestDepth
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
  @Shared(.appStorage("worktreeRowDisplayMode")) private var displayMode: WorktreeRowDisplayMode = .branchFirst
  @Shared(.appStorage("worktreeRowHideSubtitleOnMatch")) private var hideSubtitleOnMatch = true

  var body: some View {
    let rowID = store.state.id
    let lifecycle = store.lifecycle
    let isDragging = store.isDragging
    let moveDisabled: Bool =
      switch moveMode {
      case .alwaysDisabled: true
      case .alwaysEnabled: false
      case .conditional: isRepositoryRemoving || lifecycle == .deleting || lifecycle == .archiving
      }
    SidebarItemView(
      store: store,
      displayMode: displayMode,
      hideSubtitle: hideSubtitle,
      hideSubtitleOnMatch: hideSubtitleOnMatch,
      showsPullRequestInfo: !isDragging,
      shortcutHint: shortcutHint,
      displayNameOverride: displayNameOverride,
      nestDepth: nestDepth
    )
    .environment(\.focusNotificationAction) { notification in
      guard let terminalState = terminalManager.stateIfExists(for: rowID) else {
        notificationLogger.warning(
          "No terminal state for worktree \(rowID) when focusing notification \(notification.surfaceId).")
        return
      }
      if !terminalState.focusSurface(id: notification.surfaceId) {
        notificationLogger.warning("Failed to focus surface \(notification.surfaceId) for worktree \(rowID).")
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

/// Folder repos render one row that must be a direct child of the outer `.onMove` to receive repo-level drags.
struct SidebarFolderRow: View {
  let repository: Repository
  let hotkeyIDs: [Worktree.ID]
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let state = store.state
    let isRepositoryRemoving = state.isRemovingRepository(repository)
    if let rowID = state.sidebarGrouping.bucketsByRepository[repository.id]?[.pinned].first {
      SidebarItemRow(
        rowID: rowID,
        store: store,
        terminalManager: terminalManager,
        selectedWorktreeIDs: selectedWorktreeIDs,
        isRepositoryRemoving: isRepositoryRemoving,
        hideSubtitle: true,
        moveMode: .alwaysEnabled,
        shortcutHint: shortcutHint(for: rowID)
      )
    }
  }

  // Folder rows show a single hint, so a linear scan beats allocating a dict per render.
  private func shortcutHint(for rowID: Worktree.ID) -> String? {
    guard commandKeyObserver.isPressed,
      let index = hotkeyIDs.firstIndex(of: rowID)
    else { return nil }
    return AppShortcuts.worktreeSelectionShortcutDisplay(
      atSlot: index,
      overrides: settingsFile.global.shortcutOverrides
    )
  }
}

private enum SidebarShortcutIndex {
  /// Defensive against a forged bucket roster: a duplicate `Worktree.ID` would trap
  /// `Dictionary(uniqueKeysWithValues:)` inside the SwiftUI render loop. Keep the first
  /// slot and fire loudly in DEBUG so a real invariant break surfaces in dev, not prod.
  static func build(from hotkeyIDs: [Worktree.ID]) -> [Worktree.ID: Int] {
    Dictionary(hotkeyIDs.enumerated().map { ($0.element, $0.offset) }) { first, _ in
      assertionFailure("Duplicate Worktree.ID in sidebar hotkey order.")
      return first
    }
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

    if !isBulkSelection {
      openActions(overrides: overrides)
      Divider()
    }

    let pinnableRows = contextRows.filter { !$0.isMainWorktree }
    if !pinnableRows.isEmpty {
      let allPinned = pinnableRows.allSatisfy(\.isPinned)
      if allPinned {
        let label = isBulkSelection ? "Unpin Worktrees" : "Unpin Worktree"
        Button(label, systemImage: "pin.slash") {
          for pinnableRow in pinnableRows {
            togglePin(for: pinnableRow.id, isPinned: true)
          }
        }
      } else {
        let label = isBulkSelection ? "Pin Worktrees" : "Pin Worktree"
        Button(label, systemImage: "pin") {
          for pinnableRow in pinnableRows where !pinnableRow.isPinned {
            togglePin(for: pinnableRow.id, isPinned: false)
          }
        }
      }
      Divider()
    }

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
      Divider()
      if rowIsFolder {
        // Folder rows have no section ellipsis menu, so Settings lives here.
        Button("Folder Settings…", systemImage: "gear") {
          store.send(.openRepositorySettings(repositoryID))
        }
        .help("Open folder settings")
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
