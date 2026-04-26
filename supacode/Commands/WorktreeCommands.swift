import AppKit
import ComposableArchitecture
import Sharing
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

struct WorktreeCommands: Commands {
  @Bindable var store: StoreOf<AppFeature>
  @FocusedValue(\.openSelectedWorktreeAction) private var openSelectedWorktreeAction
  @FocusedValue(\.revealInFinderAction) private var revealInFinderAction
  @FocusedValue(\.openActionSelection) private var openActionSelection
  @FocusedValue(\.confirmWorktreeAction) private var confirmWorktreeAction
  @FocusedValue(\.archiveWorktreeAction) private var archiveWorktreeAction
  @FocusedValue(\.deleteWorktreeAction) private var deleteWorktreeAction
  @FocusedValue(\.runScriptAction) private var runScriptAction
  @FocusedValue(\.stopRunScriptAction) private var stopRunScriptAction
  @FocusedValue(\.visibleHotkeyWorktreeRows) private var visibleHotkeyWorktreeRows

  init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  var body: some Commands {
    let overrides = store.settings.shortcutOverrides
    let repositories = store.repositories
    let orderedRows = visibleHotkeyWorktreeRows ?? repositories.orderedSidebarItems()
    let pullRequestURL = selectedPullRequestURL
    let githubIntegrationEnabled = store.settings.githubIntegrationEnabled
    let selectNext = AppShortcuts.selectNextWorktree.effective(from: overrides)
    let selectPrevious = AppShortcuts.selectPreviousWorktree.effective(from: overrides)
    let historyBack = AppShortcuts.worktreeHistoryBack.effective(from: overrides)
    let historyForward = AppShortcuts.worktreeHistoryForward.effective(from: overrides)
    let canGoBack = repositories.canNavigateWorktreeHistoryBackward
    let canGoForward = repositories.canNavigateWorktreeHistoryForward
    let archive = AppShortcuts.archiveWorktree.effective(from: overrides)
    let deleteWt = AppShortcuts.deleteWorktree.effective(from: overrides)
    let confirm = AppShortcuts.confirmWorktreeAction.effective(from: overrides)
    let openRepo = AppShortcuts.openRepository.effective(from: overrides)
    let openWorktree = AppShortcuts.openWorktree.effective(from: overrides)
    let revealInFinder = AppShortcuts.revealInFinder.effective(from: overrides)
    let openPR = AppShortcuts.openPullRequest.effective(from: overrides)
    let newWt = AppShortcuts.newWorktree.effective(from: overrides)
    let archived = AppShortcuts.archivedWorktrees.effective(from: overrides)
    let refresh = AppShortcuts.refreshWorktrees.effective(from: overrides)
    let run = AppShortcuts.runScript.effective(from: overrides)
    let stop = AppShortcuts.stopRunScript.effective(from: overrides)
    let jumpToLatestUnread = AppShortcuts.jumpToLatestUnread.effective(from: overrides)
    CommandMenu("Worktrees") {
      // Creation and opening.
      Button("New Worktree…", systemImage: "plus") {
        store.send(.repositories(.createRandomWorktree))
      }
      .appKeyboardShortcut(newWt)
      .help("New Worktree (\(newWt?.display ?? "none"))")
      .disabled(!repositories.canCreateWorktree)
      Divider()
      let openLabel = openActionSelection.map { "Open in \($0.labelTitle)" } ?? "Open"
      Button(openLabel, systemImage: "arrow.up.right.square") {
        openSelectedWorktreeAction?()
      }
      .appKeyboardShortcut(openWorktree)
      .help("\(openLabel) (\(openWorktree?.display ?? "none"))")
      .disabled(openSelectedWorktreeAction == nil)
      Button("Reveal in Finder", systemImage: "folder") {
        revealInFinderAction?()
      }
      .appKeyboardShortcut(revealInFinder)
      .help("Reveal in Finder (\(revealInFinder?.display ?? "none"))")
      .disabled(revealInFinderAction == nil)
      Button("Open Pull Request", systemImage: "arrow.up.forward") {
        if let pullRequestURL {
          NSWorkspace.shared.open(pullRequestURL)
        }
      }
      .appKeyboardShortcut(openPR)
      .help("Open Pull Request (\(openPR?.display ?? "none"))")
      .disabled(pullRequestURL == nil || !githubIntegrationEnabled)
      Divider()
      // Lifecycle.
      Button("Refresh Worktrees", systemImage: "arrow.clockwise") {
        store.send(.repositories(.refreshWorktrees))
      }
      .appKeyboardShortcut(refresh)
      .help("Refresh (\(refresh?.display ?? "none"))")
      .disabled(!repositories.isInitialLoadComplete)
      Button("Archived Worktrees", systemImage: "archivebox") {
        store.send(.repositories(.selectArchivedWorktrees))
      }
      .appKeyboardShortcut(archived)
      .help("Archived Worktrees (\(archived?.display ?? "none"))")
      .disabled(!repositories.isInitialLoadComplete)
      Divider()
      // Commands.
      Button("Archive Worktree…", systemImage: "archivebox") {
        archiveWorktreeAction?()
      }
      .appKeyboardShortcut(archive)
      .help("Archive Worktree (\(archive?.display ?? "none"))")
      .disabled(archiveWorktreeAction == nil)
      Button("Delete Worktree…", systemImage: "trash") {
        deleteWorktreeAction?()
      }
      .appKeyboardShortcut(deleteWt)
      .help("Delete Worktree (\(deleteWt?.display ?? "none"))")
      .disabled(deleteWorktreeAction == nil)
      Divider()
      // Scripts.
      Button("Run Script", systemImage: ScriptKind.run.defaultSystemImage) {
        runScriptAction?()
      }
      .appKeyboardShortcut(run)
      .help("Run Script (\(run?.display ?? "none"))")
      .disabled(runScriptAction == nil)
      Button("Stop Script", systemImage: "stop") {
        stopRunScriptAction?()
      }
      .appKeyboardShortcut(stop)
      .help("Stop Script (\(stop?.display ?? "none"))")
      .disabled(stopRunScriptAction == nil)
      Button("Jump to Latest Unread", systemImage: "bell.badge") {
        store.send(.jumpToLatestUnread)
      }
      .appKeyboardShortcut(jumpToLatestUnread)
      .help("Jump to Latest Unread Notification (\(jumpToLatestUnread?.display ?? "none"))")
      .disabled(store.notificationIndicatorCount == 0)
      Divider()
      // Navigation.
      Button("Select Next", systemImage: "chevron.down") {
        store.send(.repositories(.selectNextWorktree))
      }
      .appKeyboardShortcut(selectNext)
      .help("Select Next (\(selectNext?.display ?? "none"))")
      .disabled(orderedRows.isEmpty)
      Button("Select Previous", systemImage: "chevron.up") {
        store.send(.repositories(.selectPreviousWorktree))
      }
      .appKeyboardShortcut(selectPrevious)
      .help("Select Previous (\(selectPrevious?.display ?? "none"))")
      .disabled(orderedRows.isEmpty)
      Button("Back in Worktree History", systemImage: "chevron.left") {
        store.send(.repositories(.worktreeHistoryBack))
      }
      .appKeyboardShortcut(historyBack)
      .help("Back in Worktree History (\(historyBack?.display ?? "none"))")
      .disabled(!canGoBack)
      Button("Forward in Worktree History", systemImage: "chevron.right") {
        store.send(.repositories(.worktreeHistoryForward))
      }
      .appKeyboardShortcut(historyForward)
      .help("Forward in Worktree History (\(historyForward?.display ?? "none"))")
      .disabled(!canGoForward)
      // Direct worktree shortcuts.
      let worktreeShortcutsList = worktreeShortcuts(from: overrides)
      Menu("Select Worktree") {
        ForEach(worktreeShortcutsList.indices, id: \.self) { index in
          WorktreeShortcutButton(
            index: index,
            shortcut: worktreeShortcutsList[index],
            orderedRows: orderedRows,
            store: store
          )
        }
      }
    }
    CommandGroup(replacing: .newItem) {
      Button("Add Repository or Folder...", systemImage: "folder.badge.plus") {
        store.send(.repositories(.setOpenPanelPresented(true)))
      }
      .appKeyboardShortcut(openRepo)
      .help("Add Repository or Folder (\(openRepo?.display ?? "none"))")
      Button("Confirm Action") {
        confirmWorktreeAction?()
      }
      .appKeyboardShortcut(confirm)
      .help("Confirm Action (\(confirm?.display ?? "none"))")
      .disabled(confirmWorktreeAction == nil)
    }
  }

  private func worktreeShortcuts(from overrides: [AppShortcutID: AppShortcutOverride]) -> [AppShortcut?] {
    AppShortcuts.worktreeSelection.map { $0.effective(from: overrides) }
  }

  private var selectedPullRequestURL: URL? {
    let repositories = store.repositories
    guard let selectedWorktreeID = repositories.selectedWorktreeID else { return nil }
    let pullRequest = repositories.worktreeInfoByID[selectedWorktreeID]?.pullRequest
    return pullRequest.flatMap { URL(string: $0.url) }
  }

}

private struct WorktreeShortcutButton: View {
  let index: Int
  let shortcut: AppShortcut?
  let orderedRows: [SidebarItemModel]
  let store: StoreOf<AppFeature>

  private var row: SidebarItemModel? {
    orderedRows.indices.contains(index) ? orderedRows[index] : nil
  }

  private var title: String {
    guard let row else { return "Worktree \(index + 1)" }
    let repositoryName = store.repositories.repositoryName(for: row.repositoryID) ?? "Repository"
    return "\(repositoryName) — \(row.name)"
  }

  var body: some View {
    Button(title) {
      guard let row else { return }
      store.send(.repositories(.selectWorktree(row.id)))
    }
    .appKeyboardShortcut(shortcut)
    .help("Switch to \(title) (\(shortcut?.display ?? "none"))")
    .disabled(row == nil)
  }
}

private struct ArchiveWorktreeActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct OpenSelectedWorktreeActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct RevealInFinderActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct OpenActionSelectionKey: FocusedValueKey {
  typealias Value = OpenWorktreeAction
}

private struct DeleteWorktreeActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct ConfirmWorktreeActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var openSelectedWorktreeAction: (() -> Void)? {
    get { self[OpenSelectedWorktreeActionKey.self] }
    set { self[OpenSelectedWorktreeActionKey.self] = newValue }
  }

  var revealInFinderAction: (() -> Void)? {
    get { self[RevealInFinderActionKey.self] }
    set { self[RevealInFinderActionKey.self] = newValue }
  }

  var openActionSelection: OpenWorktreeAction? {
    get { self[OpenActionSelectionKey.self] }
    set { self[OpenActionSelectionKey.self] = newValue }
  }

  var confirmWorktreeAction: (() -> Void)? {
    get { self[ConfirmWorktreeActionKey.self] }
    set { self[ConfirmWorktreeActionKey.self] = newValue }
  }

  var archiveWorktreeAction: (() -> Void)? {
    get { self[ArchiveWorktreeActionKey.self] }
    set { self[ArchiveWorktreeActionKey.self] = newValue }
  }

  var deleteWorktreeAction: (() -> Void)? {
    get { self[DeleteWorktreeActionKey.self] }
    set { self[DeleteWorktreeActionKey.self] = newValue }
  }

  var runScriptAction: (() -> Void)? {
    get { self[RunScriptActionKey.self] }
    set { self[RunScriptActionKey.self] = newValue }
  }

  var stopRunScriptAction: (() -> Void)? {
    get { self[StopRunScriptActionKey.self] }
    set { self[StopRunScriptActionKey.self] = newValue }
  }

  var visibleHotkeyWorktreeRows: [SidebarItemModel]? {
    get { self[VisibleHotkeyWorktreeRowsKey.self] }
    set { self[VisibleHotkeyWorktreeRowsKey.self] = newValue }
  }
}

private struct RunScriptActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct StopRunScriptActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct VisibleHotkeyWorktreeRowsKey: FocusedValueKey {
  typealias Value = [SidebarItemModel]
}
