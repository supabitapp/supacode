import AppKit
import ComposableArchitecture
import Sharing
import SwiftUI

struct WorktreeRowsView: View {
  let repository: Repository
  let isExpanded: Bool
  let hotkeyRows: [WorktreeRowModel]
  let selectedWorktreeIDs: Set<Worktree.ID>
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Environment(\.colorScheme) private var colorScheme
  @State private var draggingWorktreeIDs: Set<Worktree.ID> = []
  @State private var hoveredWorktreeID: Worktree.ID?

  var body: some View {
    if isExpanded {
      expandedRowsView
    }
  }

  private var expandedRowsView: some View {
    let state = store.state
    let sections = state.worktreeRowSections(in: repository)
    let isRepositoryRemoving = state.isRemovingRepository(repository)
    let showShortcutHints = commandKeyObserver.isPressed
    let allRows = showShortcutHints ? hotkeyRows : []
    let shortcutIndexByID = Dictionary(
      uniqueKeysWithValues: allRows.enumerated().map { ($0.element.id, $0.offset) }
    )
    let rowIDs = sections.allRows.map(\.id)
    return rowsGroup(
      sections: sections,
      isRepositoryRemoving: isRepositoryRemoving,
      showShortcutHints: showShortcutHints,
      shortcutIndexByID: shortcutIndexByID
    )
    .animation(.easeOut(duration: 0.2), value: rowIDs)
  }

  @ViewBuilder
  private func rowsGroup(
    sections: WorktreeRowSections,
    isRepositoryRemoving: Bool,
    showShortcutHints: Bool,
    shortcutIndexByID: [Worktree.ID: Int]
  ) -> some View {
    if let row = sections.main {
      rowView(
        row,
        isRepositoryRemoving: isRepositoryRemoving,
        moveDisabled: true,
        shortcutHint: showShortcutHints ? worktreeShortcutHint(for: shortcutIndexByID[row.id]) : nil
      )
    }
    ForEach(sections.pinned) { row in
      rowView(
        row,
        isRepositoryRemoving: isRepositoryRemoving,
        moveDisabled: isRepositoryRemoving || row.isDeleting || row.isArchiving,
        shortcutHint: showShortcutHints ? worktreeShortcutHint(for: shortcutIndexByID[row.id]) : nil
      )
    }
    .onMove { offsets, destination in
      store.send(.pinnedWorktreesMoved(repositoryID: repository.id, offsets, destination))
    }
    ForEach(sections.pending) { row in
      rowView(
        row,
        isRepositoryRemoving: isRepositoryRemoving,
        moveDisabled: true,
        shortcutHint: showShortcutHints ? worktreeShortcutHint(for: shortcutIndexByID[row.id]) : nil
      )
    }
    ForEach(sections.unpinned) { row in
      rowView(
        row,
        isRepositoryRemoving: isRepositoryRemoving,
        moveDisabled: isRepositoryRemoving || row.isDeleting || row.isArchiving,
        shortcutHint: showShortcutHints ? worktreeShortcutHint(for: shortcutIndexByID[row.id]) : nil
      )
    }
    .onMove { offsets, destination in
      store.send(.unpinnedWorktreesMoved(repositoryID: repository.id, offsets, destination))
    }
  }

  @ViewBuilder
  private func rowView(
    _ row: WorktreeRowModel,
    isRepositoryRemoving: Bool,
    moveDisabled: Bool,
    shortcutHint: String?
  ) -> some View {
    let showsNotificationIndicator = terminalManager.hasUnseenNotifications(for: row.id)
    let displayName =
      if row.isDeleting {
        "\(row.name) (deleting...)"
      } else if row.isArchiving {
        "\(row.name) (archiving...)"
      } else {
        row.name
      }
    let canShowRowActions = row.isRemovable && !isRepositoryRemoving
    let pinAction: (() -> Void)? =
      canShowRowActions && !row.isMainWorktree
      ? { togglePin(for: row.id, isPinned: row.isPinned) }
      : nil
    let archiveAction: (() -> Void)? =
      canShowRowActions && !row.isMainWorktree && !row.isArchiving
      ? { archiveWorktree(row.id) }
      : nil
    let notifications = terminalManager.stateIfExists(for: row.id)?.notifications ?? []
    let onFocusNotification: (WorktreeTerminalNotification) -> Void = { notification in
      guard let terminalState = terminalManager.stateIfExists(for: row.id) else {
        return
      }
      _ = terminalState.focusSurface(id: notification.surfaceId)
    }
    let config = WorktreeRowViewConfig(
      displayName: displayName,
      worktreeName: worktreeName(for: row),
      isHovered: hoveredWorktreeID == row.id,
      showsNotificationIndicator: showsNotificationIndicator,
      notifications: notifications,
      onFocusNotification: onFocusNotification,
      shortcutHint: shortcutHint,
      pinAction: pinAction,
      archiveAction: archiveAction,
      moveDisabled: moveDisabled
    )
    let baseRow = worktreeRowView(row, config: config)
    Group {
      if row.isRemovable, let worktree = store.state.worktree(for: row.id), !isRepositoryRemoving {
        baseRow.contextMenu {
          rowContextMenu(worktree: worktree, row: row)
        }
      } else {
        baseRow.disabled(isRepositoryRemoving)
      }
    }
    .contentShape(.dragPreview, .rect)
    .contentShape(.interaction, .rect)
    .environment(\.colorScheme, colorScheme)
    .preferredColorScheme(colorScheme)
    .onHover { hovering in
      if hovering {
        hoveredWorktreeID = row.id
      } else if hoveredWorktreeID == row.id {
        hoveredWorktreeID = nil
      }
    }
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

  private struct WorktreeRowViewConfig {
    let displayName: String
    let worktreeName: String
    let isHovered: Bool
    let showsNotificationIndicator: Bool
    let notifications: [WorktreeTerminalNotification]
    let onFocusNotification: (WorktreeTerminalNotification) -> Void
    let shortcutHint: String?
    let pinAction: (() -> Void)?
    let archiveAction: (() -> Void)?
    let moveDisabled: Bool
  }

  private func worktreeRowView(_ row: WorktreeRowModel, config: WorktreeRowViewConfig) -> some View {
    let isSelected = selectedWorktreeIDs.contains(row.id)
    let taskStatus = terminalManager.taskStatus(for: row.id)
    let isRunScriptRunning = terminalManager.isRunScriptRunning(for: row.id)
    return WorktreeRow(
      name: config.displayName,
      worktreeName: config.worktreeName,
      info: row.info,
      showsPullRequestInfo: !draggingWorktreeIDs.contains(row.id),
      isHovered: config.isHovered,
      isPinned: row.isPinned,
      isMainWorktree: row.isMainWorktree,
      isLoading: row.isPending || row.isArchiving || row.isDeleting,
      taskStatus: taskStatus,
      isRunScriptRunning: isRunScriptRunning,
      showsNotificationIndicator: config.showsNotificationIndicator,
      notifications: config.notifications,
      onFocusNotification: config.onFocusNotification,
      shortcutHint: config.shortcutHint,
      pinAction: config.pinAction,
      isSelected: isSelected,
      archiveAction: config.archiveAction
    )
    .tag(SidebarSelection.worktree(row.id))
    .typeSelectEquivalent("")
    .listRowInsets(EdgeInsets())
    .listRowSeparator(.hidden)
    .transition(.opacity)
    .moveDisabled(config.moveDisabled)
  }

  @ViewBuilder
  private func rowContextMenu(worktree: Worktree, row: WorktreeRowModel) -> some View {
    let archiveShortcut = KeyboardShortcut(.delete, modifiers: .command).display
    let deleteShortcut = KeyboardShortcut(.delete, modifiers: [.command, .shift]).display
    let contextRows = contextActionRows(for: row)
    let isBulkSelection = contextRows.count > 1
    let archiveTargets =
      contextRows
      .filter { !$0.isMainWorktree && !$0.isArchiving }
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
    let archiveTitle =
      isBulkSelection
      ? "Archive Selected Worktrees (\(archiveShortcut))"
      : "Archive Worktree (\(archiveShortcut))"
    let deleteTitle =
      isBulkSelection
      ? "Delete Selected Worktrees (\(deleteShortcut))"
      : "Delete Worktree (\(deleteShortcut))"
    if !row.isMainWorktree {
      if row.isPinned {
        Button("Unpin") {
          togglePin(for: worktree.id, isPinned: true)
        }
        .help("Unpin")
      } else {
        Button("Pin to top") {
          togglePin(for: worktree.id, isPinned: false)
        }
        .help("Pin to top")
      }
    }
    Button("Copy Path") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(worktree.workingDirectory.path, forType: .string)
    }
    Button(archiveTitle) {
      archiveWorktrees(archiveTargets)
    }
    .help(
      archiveTargets.isEmpty
        ? "Main worktree can't be archived"
        : archiveTitle
    )
    .disabled(archiveTargets.isEmpty)
    Button(deleteTitle, role: .destructive) {
      deleteWorktrees(deleteTargets)
    }
    .help(deleteTitle)
  }

  private func worktreeShortcutHint(for index: Int?) -> String? {
    guard let index, AppShortcuts.worktreeSelection.indices.contains(index) else { return nil }
    @Shared(.settingsFile) var settingsFile
    let overrides = settingsFile.global.shortcutOverrides
    return AppShortcuts.worktreeSelection[index].effective(from: overrides)?.display
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

  private func archiveWorktree(_ worktreeID: Worktree.ID) {
    store.send(.requestArchiveWorktree(worktreeID, repository.id))
  }

  private func contextActionRows(for row: WorktreeRowModel) -> [WorktreeRowModel] {
    guard selectedWorktreeIDs.count > 1, selectedWorktreeIDs.contains(row.id) else {
      return [row]
    }
    let rows = selectedWorktreeIDs.compactMap { store.state.selectedRow(for: $0) }
    return rows.isEmpty ? [row] : rows
  }

  private func archiveWorktrees(_ targets: [RepositoriesFeature.ArchiveWorktreeTarget]) {
    guard !targets.isEmpty else { return }
    if targets.count == 1, let target = targets.first {
      store.send(.requestArchiveWorktree(target.worktreeID, target.repositoryID))
    } else {
      store.send(.requestArchiveWorktrees(targets))
    }
  }

  private func deleteWorktrees(_ targets: [RepositoriesFeature.DeleteWorktreeTarget]) {
    guard !targets.isEmpty else { return }
    if targets.count == 1, let target = targets.first {
      store.send(.requestDeleteWorktree(target.worktreeID, target.repositoryID))
    } else {
      store.send(.requestDeleteWorktrees(targets))
    }
  }

  private func worktreeName(for row: WorktreeRowModel) -> String {
    if row.isMainWorktree {
      return "Default"
    }
    if row.isPending {
      return row.detail
    }
    if row.id.contains("/") {
      let pathName = URL(fileURLWithPath: row.id).lastPathComponent
      if !pathName.isEmpty {
        return pathName
      }
    }
    if !row.detail.isEmpty, row.detail != "." {
      let detailName = URL(fileURLWithPath: row.detail).lastPathComponent
      if !detailName.isEmpty, detailName != "." {
        return detailName
      }
    }
    return row.name
  }
}
