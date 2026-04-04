import AppKit
import ComposableArchitecture
import Sharing
import SwiftUI

private nonisolated let notificationLogger = SupaLogger("Notifications")

struct WorktreeRowsView: View {
  private struct GroupConfiguration: Identifiable {
    let id: String
    let rows: [WorktreeRowModel]
    let hideSubtitle: Bool
    let moveBehavior: WorktreeRowGroupView.MoveBehavior
  }

  let repository: Repository
  let hotkeyRows: [WorktreeRowModel]
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @State private var draggingWorktreeIDs: Set<Worktree.ID> = []

  var body: some View {
    let state = store.state
    let sections = state.worktreeRowSections(in: repository)
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
      WorktreeRowGroupView(
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

private struct WorktreeRowGroupView: View {
  enum MoveBehavior: Hashable {
    case disabled
    case pinned(Repository.ID)
    case unpinned(Repository.ID)
  }

  let rows: [WorktreeRowModel]
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Binding var draggingWorktreeIDs: Set<Worktree.ID>
  let isRepositoryRemoving: Bool
  let hideSubtitle: Bool
  let moveBehavior: MoveBehavior
  let shortcutIndexByID: [Worktree.ID: Int]

  var body: some View {
    ForEach(rows) { row in
      WorktreeRowContainer(
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
    .onMove(perform: moveRows)
  }

  private func moveDisabled(for row: WorktreeRowModel) -> Bool {
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

private struct WorktreeRowContainer: View {
  let row: WorktreeRowModel
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

  var body: some View {
    WorktreeRow(
      row: row,
      displayMode: displayMode,
      hideSubtitle: hideSubtitle,
      hideSubtitleOnMatch: hideSubtitleOnMatch,
      showsPullRequestInfo: !draggingWorktreeIDs.contains(row.id),
      isRunScriptRunning: store.state.runScriptWorktreeIDs.contains(row.id),
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
        WorktreeContextMenu(
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

// MARK: - Context menu.

private struct WorktreeContextMenu: View {
  let worktree: Worktree
  let row: WorktreeRowModel
  @Bindable var store: StoreOf<RepositoriesFeature>
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Shared(.settingsFile) private var settingsFile

  private var contextRows: [WorktreeRowModel] {
    guard selectedWorktreeIDs.count > 1, selectedWorktreeIDs.contains(row.id) else {
      return [row]
    }
    let rows = selectedWorktreeIDs.compactMap { store.state.selectedRow(for: $0) }
    return rows.isEmpty ? [row] : rows
  }

  var body: some View {
    let contextRows = contextRows
    let isBulkSelection = contextRows.count > 1
    let overrides = settingsFile.global.shortcutOverrides
    let archiveShortcut = AppShortcuts.archiveWorktree.effective(from: overrides)
    let deleteShortcut = AppShortcuts.deleteWorktree.effective(from: overrides)

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
      Button("Copy as Branch Name") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(worktree.name, forType: .string)
      }
      Divider()
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

    let archiveLabel = isBulkSelection ? "Archive Worktrees…" : "Archive Worktree…"
    Button(archiveLabel, systemImage: "archivebox") {
      if archiveTargets.count == 1, let target = archiveTargets.first {
        store.send(.requestArchiveWorktree(target.worktreeID, target.repositoryID))
      } else {
        store.send(.requestArchiveWorktrees(archiveTargets))
      }
    }
    .appKeyboardShortcut(archiveShortcut)
    .disabled(archiveTargets.isEmpty)

    let deleteLabel = isBulkSelection ? "Delete Worktrees…" : "Delete Worktree…"
    Button(deleteLabel, systemImage: "trash", role: .destructive) {
      if deleteTargets.count == 1, let target = deleteTargets.first {
        store.send(.requestDeleteWorktree(target.worktreeID, target.repositoryID))
      } else {
        store.send(.requestDeleteWorktrees(deleteTargets))
      }
    }
    .appKeyboardShortcut(deleteShortcut)
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
