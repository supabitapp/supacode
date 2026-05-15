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

  var body: some View {
    let groups = sidebarItemGroups(in: store.state, repositoryID: repository.id)
    let isRepositoryRemoving = store.state.isRemovingRepository(repository)
    let showShortcutHints = commandKeyObserver.isPressed
    let shortcutIndexByID: [Worktree.ID: Int] =
      showShortcutHints ? shortcutIndex(for: hotkeyIDs) : [:]

    SidebarItemsDragOverlay(
      groups: groups,
      selectedWorktreeIDs: selectedWorktreeIDs,
      store: store,
      terminalManager: terminalManager,
      isRepositoryRemoving: isRepositoryRemoving,
      shortcutIndexByID: shortcutIndexByID
    )
  }
}

/// Drag highlights now live on each `SidebarItemFeature.State.isDragging`; the
/// overlay struct is kept for code locality but holds no state of its own.
private struct SidebarItemsDragOverlay: View {
  let groups: [SidebarItemGroup]
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let isRepositoryRemoving: Bool
  let shortcutIndexByID: [Worktree.ID: Int]

  var body: some View {
    ForEach(groups) { group in
      SidebarItemGroupView(
        rowIDs: group.rowIDs,
        selectedWorktreeIDs: selectedWorktreeIDs,
        store: store,
        terminalManager: terminalManager,
        isRepositoryRemoving: isRepositoryRemoving,
        hideSubtitle: group.hideSubtitle,
        moveBehavior: group.moveBehavior,
        shortcutIndexByID: shortcutIndexByID
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
}

func sidebarItemGroups(
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
    SidebarItemGroup(
      slot: .pinnedTail,
      repositoryID: repositoryID,
      rowIDs: pinnedTail
    ),
    SidebarItemGroup(
      slot: .pending,
      repositoryID: repositoryID,
      rowIDs: pendingTail
    ),
    SidebarItemGroup(
      slot: .unpinnedTail,
      repositoryID: repositoryID,
      rowIDs: unpinnedTail
    ),
  ]
}

private struct SidebarItemGroupView: View {
  let rowIDs: [SidebarItemID]
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let isRepositoryRemoving: Bool
  let hideSubtitle: Bool
  let moveBehavior: SidebarItemGroup.MoveBehavior
  let shortcutIndexByID: [Worktree.ID: Int]

  var body: some View {
    // A no-op `.onMove` still steals the repo-level reorder gesture, so omit it for single-row groups.
    switch moveBehavior {
    case .disabled:
      ForEach(rowIDs, id: \.self) { rowID in
        SidebarItemRow(
          rowID: rowID,
          store: store,
          terminalManager: terminalManager,
          selectedWorktreeIDs: selectedWorktreeIDs,
          isRepositoryRemoving: isRepositoryRemoving,
          hideSubtitle: hideSubtitle,
          moveMode: .alwaysDisabled,
          shortcutHint: shortcutHint(for: shortcutIndexByID[rowID])
        )
      }
    case .pinned, .unpinned:
      ForEach(rowIDs, id: \.self) { rowID in
        SidebarItemRow(
          rowID: rowID,
          store: store,
          terminalManager: terminalManager,
          selectedWorktreeIDs: selectedWorktreeIDs,
          isRepositoryRemoving: isRepositoryRemoving,
          hideSubtitle: hideSubtitle,
          moveMode: .conditional,
          shortcutHint: shortcutHint(for: shortcutIndexByID[rowID])
        )
      }
      .onMove(perform: moveRows)
    }
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
        shortcutHint: shortcutHint
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
      shortcutHint: shortcutHint
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

/// Defensive against a forged bucket roster: a duplicate `Worktree.ID` would trap
/// `Dictionary(uniqueKeysWithValues:)` inside the SwiftUI render loop. Keep the first
/// slot and fire loudly in DEBUG so a real invariant break surfaces in dev, not prod.
private func shortcutIndex(for hotkeyIDs: [Worktree.ID]) -> [Worktree.ID: Int] {
  Dictionary(hotkeyIDs.enumerated().map { ($0.element, $0.offset) }) { first, _ in
    assertionFailure("Duplicate Worktree.ID in sidebar hotkey order.")
    return first
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
