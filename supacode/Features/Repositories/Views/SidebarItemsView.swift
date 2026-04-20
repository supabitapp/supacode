import AppKit
import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

private nonisolated let notificationLogger = SupaLogger("Notifications")

struct SidebarItemsView: View {
  private struct GroupConfiguration: Identifiable {
    let id: String
    let rows: [SidebarItemModel]
    let hideSubtitle: Bool
    let moveBehavior: SidebarItemGroupView.MoveBehavior
  }

  let repository: Repository
  let hotkeyRows: [SidebarItemModel]
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @State private var draggingWorktreeIDs: Set<Worktree.ID> = []

  var body: some View {
    let state = store.state
    let sections = state.sidebarItemSections(in: repository)
    let isSoleDefaultWorktree = sections.allRows.count == 1 && sections.main != nil
    let isRepositoryRemoving = state.isRemovingRepository(repository)
    let showShortcutHints = commandKeyObserver.isPressed
    let shortcutIndexByID: [Worktree.ID: Int] =
      showShortcutHints
      ? Dictionary(uniqueKeysWithValues: hotkeyRows.enumerated().map { ($0.element.id, $0.offset) })
      : [:]
    let groupConfigurations = [
      GroupConfiguration(
        id: "main",
        rows: sections.main.map { [$0] } ?? [],
        hideSubtitle: isSoleDefaultWorktree,
        moveBehavior: .disabled
      ),
      GroupConfiguration(
        id: "pinned",
        rows: sections.pinned,
        hideSubtitle: false,
        moveBehavior: .pinned(repository.id)
      ),
      GroupConfiguration(
        id: "pending",
        rows: sections.pending,
        hideSubtitle: false,
        moveBehavior: .disabled
      ),
      GroupConfiguration(
        id: "unpinned",
        rows: sections.unpinned,
        hideSubtitle: false,
        moveBehavior: .unpinned(repository.id)
      ),
    ]

    ForEach(groupConfigurations) { groupConfiguration in
      SidebarItemGroupView(
        rows: groupConfiguration.rows,
        selectedWorktreeIDs: selectedWorktreeIDs,
        store: store,
        terminalManager: terminalManager,
        draggingWorktreeIDs: $draggingWorktreeIDs,
        isRepositoryRemoving: isRepositoryRemoving,
        hideSubtitle: groupConfiguration.hideSubtitle,
        moveBehavior: groupConfiguration.moveBehavior,
        shortcutIndexByID: shortcutIndexByID
      )
    }
  }

}

private struct SidebarItemGroupView: View {
  enum MoveBehavior: Hashable {
    case disabled
    case pinned(Repository.ID)
    case unpinned(Repository.ID)
  }

  let rows: [SidebarItemModel]
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Binding var draggingWorktreeIDs: Set<Worktree.ID>
  let isRepositoryRemoving: Bool
  let hideSubtitle: Bool
  let moveBehavior: MoveBehavior
  let shortcutIndexByID: [Worktree.ID: Int]

  var body: some View {
    // Only attach `.onMove` when the group actually participates in
    // intra-section reorder. A no-op `onMove` on a single-row group
    // (e.g. the folder row or a repo's main worktree) still gets
    // picked up by SwiftUI's sidebar List as a drag target and
    // steals the repo-level reorder gesture, so the enclosing
    // section becomes un-draggable.
    switch moveBehavior {
    case .disabled:
      ForEach(rows) { row in rowContainer(for: row) }
    case .pinned, .unpinned:
      ForEach(rows) { row in rowContainer(for: row) }
        .onMove(perform: moveRows)
    }
  }

  @ViewBuilder
  private func rowContainer(for row: SidebarItemModel) -> some View {
    SidebarItemContainer(
      row: row,
      store: store,
      terminalManager: terminalManager,
      selectedWorktreeIDs: selectedWorktreeIDs,
      draggingWorktreeIDs: $draggingWorktreeIDs,
      isRepositoryRemoving: isRepositoryRemoving,
      hideSubtitle: hideSubtitle,
      moveDisabled: moveDisabled(for: row),
      shortcutHint: shortcutHint(for: shortcutIndexByID[row.id])
    )
  }

  private func moveDisabled(for row: SidebarItemModel) -> Bool {
    switch moveBehavior {
    case .disabled:
      true
    case .pinned, .unpinned:
      isRepositoryRemoving || row.isDeleting || row.isArchiving
    }
  }

  @Shared(.settingsFile) private var settingsFile

  private func shortcutHint(for index: Int?) -> String? {
    guard let index, AppShortcuts.worktreeSelection.indices.contains(index) else { return nil }
    let overrides = settingsFile.global.shortcutOverrides
    return AppShortcuts.worktreeSelection[index].effective(from: overrides)?.display
  }

  private func moveRows(_ offsets: IndexSet, _ destination: Int) {
    switch moveBehavior {
    case .disabled:
      break
    case .pinned(let repositoryID):
      store.send(.pinnedWorktreesMoved(repositoryID: repositoryID, offsets, destination))
    case .unpinned(let repositoryID):
      store.send(.unpinnedWorktreesMoved(repositoryID: repositoryID, offsets, destination))
    }
  }
}

// MARK: - Row container.

private struct SidebarItemContainer: View {
  let row: SidebarItemModel
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Binding var draggingWorktreeIDs: Set<Worktree.ID>
  let isRepositoryRemoving: Bool
  let hideSubtitle: Bool
  let moveDisabled: Bool
  let shortcutHint: String?
  @Shared(.appStorage("worktreeRowDisplayMode")) private var displayMode: WorktreeRowDisplayMode = .branchFirst
  @Shared(.appStorage("worktreeRowHideSubtitleOnMatch")) private var hideSubtitleOnMatch = true
  @Environment(\.scriptsByID) private var scriptsByID

  var body: some View {
    SidebarItemView(
      row: row,
      displayMode: displayMode,
      hideSubtitle: hideSubtitle,
      hideSubtitleOnMatch: hideSubtitleOnMatch,
      showsPullRequestInfo: !draggingWorktreeIDs.contains(row.id),
      runningScriptColors: store.state.runningScriptColors(for: row.id, scriptsByID: scriptsByID),
      isTaskRunning: terminalManager.stateIfExists(for: row.id)?.taskStatus == .running,
      showsNotificationIndicator: terminalManager.hasUnseenNotifications(for: row.id),
      notifications: terminalManager.stateIfExists(for: row.id)?.notifications ?? [],
      shortcutHint: shortcutHint
    )
    .environment(\.focusNotificationAction) { notification in
      guard let terminalState = terminalManager.stateIfExists(for: row.id) else {
        notificationLogger.warning(
          "No terminal state for worktree \(row.id) when focusing notification \(notification.surfaceId).")
        return
      }
      if !terminalState.focusSurface(id: notification.surfaceId) {
        notificationLogger.warning("Failed to focus surface \(notification.surfaceId) for worktree \(row.id).")
      }
    }
    .tag(SidebarSelection.worktree(row.id))
    .id(row.id)
    .typeSelectEquivalent("")
    .moveDisabled(moveDisabled)
    .contextMenu {
      if row.isRemovable, let worktree = store.state.worktree(for: row.id), !isRepositoryRemoving {
        SidebarItemContextMenu(
          worktree: worktree,
          row: row,
          store: store,
          selectedWorktreeIDs: selectedWorktreeIDs
        )
      }
    }
    .disabled(!row.isRemovable && isRepositoryRemoving)
    .contentShape(.dragPreview, .rect)
    .contentShape(.interaction, .rect)
    .onDragSessionUpdated { session in
      let draggedIDs = Set(session.draggedItemIDs(for: Worktree.ID.self))
      if case .ended = session.phase {
        if !draggingWorktreeIDs.isEmpty {
          draggingWorktreeIDs = []
        }
        return
      }
      if case .dataTransferCompleted = session.phase {
        if !draggingWorktreeIDs.isEmpty {
          draggingWorktreeIDs = []
        }
        return
      }
      if draggedIDs != draggingWorktreeIDs {
        draggingWorktreeIDs = draggedIDs
      }
    }
  }

}

// MARK: - Folder row.

/// Folder repositories render exactly one row (the synthesized main
/// item) and must sit as a *direct* child of the outer
/// `ForEach(sidebarRootRows)` in `SidebarListView` — otherwise the
/// enclosing `.onMove` can't route repo-level drags to the folder.
/// Bypassing `SidebarItemsView`'s nested ForEach-of-groups keeps the
/// folder row flat, matching the `SidebarFailedRepositoryRow`
/// pattern that already reorders correctly.
struct SidebarFolderRow: View {
  let repository: Repository
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @State private var draggingWorktreeIDs: Set<Worktree.ID> = []

  var body: some View {
    let state = store.state
    let isRepositoryRemoving = state.isRemovingRepository(repository)
    if let row = state.sidebarItemSections(in: repository).main {
      SidebarItemContainer(
        row: row,
        store: store,
        terminalManager: terminalManager,
        selectedWorktreeIDs: selectedWorktreeIDs,
        draggingWorktreeIDs: $draggingWorktreeIDs,
        isRepositoryRemoving: isRepositoryRemoving,
        hideSubtitle: true,
        moveDisabled: false,
        shortcutHint: nil
      )
    }
  }
}

// MARK: - Context menu.

private struct SidebarItemContextMenu: View {
  let worktree: Worktree
  let row: SidebarItemModel
  @Bindable var store: StoreOf<RepositoriesFeature>
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Shared(.settingsFile) private var settingsFile

  private var contextRows: [SidebarItemModel] {
    guard selectedWorktreeIDs.count > 1, selectedWorktreeIDs.contains(row.id) else {
      return [row]
    }
    let rows = selectedWorktreeIDs.compactMap { store.state.selectedRow(for: $0) }
    return rows.isEmpty ? [row] : rows
  }

  /// A bulk context menu only makes sense for selections whose rows
  /// are all of the same kind — the per-kind actions (archive, pin,
  /// branch-name copy, folder disk deletion) don't compose. Mixed
  /// selections surface no menu at all; the user-facing affordances
  /// for that state live in the multi-selection detail view.
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
    // A mixed folders + worktrees selection has no composable bulk
    // action, so we render no menu at all. The multi-selection
    // detail view explains what remains available per kind.
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
    contextRows: [SidebarItemModel],
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
      if !row.isFolder {
        Button("Copy as Branch Name") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(worktree.name, forType: .string)
        }
      }
      Divider()
      if row.isFolder {
        // Folder rows have no section-header ellipsis menu, so the
        // Settings entry lives alongside Delete in the context menu.
        Button("Folder Settings…", systemImage: "gear") {
          store.send(.openRepositorySettings(row.repositoryID))
        }
        .help("Open folder settings")
        Divider()
      }
    }

    let archiveTargets =
      contextRows
      .filter { !$0.isMainWorktree && !$0.isLoading }
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
        : (row.isFolder ? "Remove Folder…" : "Delete Worktree…")
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
