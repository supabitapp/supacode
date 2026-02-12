import AppKit
import ComposableArchitecture
import SwiftUI

struct WorktreeRowsView: View {
  let repository: Repository
  let isExpanded: Bool
  let hotkeyRows: [WorktreeRowModel]
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
        moveDisabled: isRepositoryRemoving || row.isDeleting,
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
        moveDisabled: isRepositoryRemoving || row.isDeleting,
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
    let displayName = row.isDeleting ? "\(row.name) (deleting...)" : row.name
    let canShowRowActions = row.isRemovable && !isRepositoryRemoving
    let pinAction: (() -> Void)? =
      canShowRowActions && !row.isMainWorktree
      ? { togglePin(for: row.id, isPinned: row.isPinned) }
      : nil
    let archiveAction: (() -> Void)? =
      canShowRowActions && !row.isMainWorktree
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
    let isSelected = row.id == store.state.selectedWorktreeID
    let taskStatus = terminalManager.focusedTaskStatus(for: row.id)
    let isRunScriptRunning = terminalManager.isRunScriptRunning(for: row.id)
    return WorktreeRow(
      name: config.displayName,
      worktreeName: config.worktreeName,
      info: row.info,
      showsPullRequestInfo: !draggingWorktreeIDs.contains(row.id),
      isHovered: config.isHovered,
      isPinned: row.isPinned,
      isMainWorktree: row.isMainWorktree,
      isLoading: row.isPending || row.isDeleting,
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
    Button("Archive Worktree (\(archiveShortcut))") {
      archiveWorktree(worktree.id)
    }
    .help(
      row.isMainWorktree
        ? "Main worktree can't be archived"
        : "Archive Worktree (\(archiveShortcut))"
    )
    .disabled(row.isMainWorktree)
    Button("Delete Worktree (\(deleteShortcut))", role: .destructive) {
      store.send(.requestDeleteWorktree(worktree.id, repository.id))
    }
    .help("Delete Worktree (\(deleteShortcut))")
  }

  private func worktreeShortcutHint(for index: Int?) -> String? {
    guard let index, AppShortcuts.worktreeSelection.indices.contains(index) else { return nil }
    return AppShortcuts.worktreeSelection[index].display
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

  private func worktreeName(for row: WorktreeRowModel) -> String {
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
