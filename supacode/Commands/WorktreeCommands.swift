import AppKit
import ComposableArchitecture
import Sharing
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

#if DEBUG
  private nonisolated let commandsRenderLogger = SupaLogger("DetailRender")
#endif

/// Umbrella that wires the worktree-related menu-bar contributions. Each
/// child is its own `Commands` struct so SwiftUI re-renders only the one
/// whose observed inputs changed; e.g. the static Select Worktree submenu
/// never re-runs during agent storms even when the main menu's snapshot
/// fields tick.
struct WorktreeCommands: Commands {
  @Bindable var store: StoreOf<AppFeature>

  var body: some Commands {
    WorktreeMainMenu(store: store)
    WorktreeFileMenu(store: store)
  }
}

/// The "Worktrees" `CommandMenu`. Re-renders when the snapshot or any read
/// focused value changes; the inner Select-Worktree submenu is its own
/// struct so its static 10-item rendering doesn't churn with the rest.
private struct WorktreeMainMenu: Commands {
  @Bindable var store: StoreOf<AppFeature>
  @FocusedValue(\.openSelectedWorktreeAction) private var openSelectedWorktreeAction
  @FocusedValue(\.revealInFinderAction) private var revealInFinderAction
  @FocusedValue(\.openActionSelection) private var openActionSelection
  @FocusedValue(\.archiveWorktreeAction) private var archiveWorktreeAction
  @FocusedValue(\.deleteWorktreeAction) private var deleteWorktreeAction
  @FocusedValue(\.runScriptAction) private var runScriptAction
  @FocusedValue(\.stopRunScriptAction) private var stopRunScriptAction

  var body: some Commands {
    #if DEBUG
      let _: Void = commandsRenderLogger.info("WorktreeMainMenu.body re-rendered")
    #endif
    let snapshot = store.worktreeMenuSnapshot
    let overrides = snapshot.shortcutOverrides
    let selectNext = AppShortcuts.selectNextWorktree.effective(from: overrides)
    let selectPrevious = AppShortcuts.selectPreviousWorktree.effective(from: overrides)
    let historyBack = AppShortcuts.worktreeHistoryBack.effective(from: overrides)
    let historyForward = AppShortcuts.worktreeHistoryForward.effective(from: overrides)
    let archive = AppShortcuts.archiveWorktree.effective(from: overrides)
    let deleteWt = AppShortcuts.deleteWorktree.effective(from: overrides)
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
      Button("New Worktree…", systemImage: "plus") {
        store.send(.repositories(.createRandomWorktree))
      }
      .appKeyboardShortcut(newWt)
      .help("New Worktree (\(newWt?.display ?? "none"))")
      .disabled(!snapshot.canCreateWorktree)
      Divider()
      let openLabel = openActionSelection.map { "Open in \($0.labelTitle)" } ?? "Open"
      Button(openLabel, systemImage: "arrow.up.right.square") {
        openSelectedWorktreeAction?()
      }
      .appKeyboardShortcut(openWorktree)
      .help("\(openLabel) (\(openWorktree?.display ?? "none"))")
      .disabled(openSelectedWorktreeAction?.isEnabled != true)
      Button("Reveal in Finder", systemImage: "folder") {
        revealInFinderAction?()
      }
      .appKeyboardShortcut(revealInFinder)
      .help("Reveal in Finder (\(revealInFinder?.display ?? "none"))")
      .disabled(revealInFinderAction?.isEnabled != true)
      Button("Open Pull Request", systemImage: "arrow.up.forward") {
        if let url = snapshot.selectedPullRequestURL {
          NSWorkspace.shared.open(url)
        }
      }
      .appKeyboardShortcut(openPR)
      .help("Open Pull Request (\(openPR?.display ?? "none"))")
      .disabled(snapshot.selectedPullRequestURL == nil || !snapshot.githubIntegrationEnabled)
      Divider()
      Button("Refresh Worktrees", systemImage: "arrow.clockwise") {
        store.send(.repositories(.refreshWorktrees))
      }
      .appKeyboardShortcut(refresh)
      .help("Refresh (\(refresh?.display ?? "none"))")
      .disabled(!snapshot.isInitialLoadComplete)
      Button("Archived Worktrees", systemImage: "archivebox") {
        store.send(.repositories(.selectArchivedWorktrees))
      }
      .appKeyboardShortcut(archived)
      .help("Archived Worktrees (\(archived?.display ?? "none"))")
      .disabled(!snapshot.isInitialLoadComplete)
      Divider()
      Button("Archive Worktree…", systemImage: "archivebox") {
        archiveWorktreeAction?()
      }
      .appKeyboardShortcut(archive)
      .help("Archive Worktree (\(archive?.display ?? "none"))")
      .disabled(archiveWorktreeAction?.isEnabled != true)
      Button("Delete Worktree…", systemImage: "trash") {
        deleteWorktreeAction?()
      }
      .appKeyboardShortcut(deleteWt)
      .help("Delete Worktree (\(deleteWt?.display ?? "none"))")
      .disabled(deleteWorktreeAction?.isEnabled != true)
      Divider()
      Button("Run Script", systemImage: ScriptKind.run.defaultSystemImage) {
        runScriptAction?()
      }
      .appKeyboardShortcut(run)
      .help("Run Script (\(run?.display ?? "none"))")
      .disabled(runScriptAction?.isEnabled != true)
      Button("Stop Script", systemImage: "stop") {
        stopRunScriptAction?()
      }
      .appKeyboardShortcut(stop)
      .help("Stop Script (\(stop?.display ?? "none"))")
      .disabled(stopRunScriptAction?.isEnabled != true)
      Button("Jump to Latest Unread", systemImage: "bell.badge") {
        store.send(.jumpToLatestUnread)
      }
      .appKeyboardShortcut(jumpToLatestUnread)
      .help("Jump to Latest Unread Notification (\(jumpToLatestUnread?.display ?? "none"))")
      .disabled(snapshot.notificationIndicatorCount == 0)
      Divider()
      // Always-enabled; the reducer beeps when there's no worktree to move to.
      Button("Select Next", systemImage: "chevron.down") {
        store.send(.repositories(.selectNextWorktree))
      }
      .appKeyboardShortcut(selectNext)
      .help("Select Next (\(selectNext?.display ?? "none"))")
      Button("Select Previous", systemImage: "chevron.up") {
        store.send(.repositories(.selectPreviousWorktree))
      }
      .appKeyboardShortcut(selectPrevious)
      .help("Select Previous (\(selectPrevious?.display ?? "none"))")
      Button("Back in Worktree History", systemImage: "chevron.left") {
        store.send(.repositories(.worktreeHistoryBack))
      }
      .appKeyboardShortcut(historyBack)
      .help("Back in Worktree History (\(historyBack?.display ?? "none"))")
      .disabled(!snapshot.canNavigateBackward)
      Button("Forward in Worktree History", systemImage: "chevron.right") {
        store.send(.repositories(.worktreeHistoryForward))
      }
      .appKeyboardShortcut(historyForward)
      .help("Forward in Worktree History (\(historyForward?.display ?? "none"))")
      .disabled(!snapshot.canNavigateForward)
      Menu("Select Worktree") {
        SelectWorktreeSubmenuItems(store: store, overrides: overrides)
      }
    }
  }
}

/// Static 10-item submenu. Labels and per-item actions never change, so the
/// menu bar doesn't rebuild during agent storms. Out-of-range slots beep at
/// fire time (handled in the reducer) so we don't need a disabled state here.
private struct SelectWorktreeSubmenuItems: View {
  let store: StoreOf<AppFeature>
  let overrides: [AppShortcutID: AppShortcutOverride]

  var body: some View {
    ForEach(0..<AppShortcuts.worktreeSelection.count, id: \.self) { index in
      let shortcut = AppShortcuts.worktreeSelection[index].effective(from: overrides)
      Button("Select Worktree \(index + 1)") {
        store.send(.repositories(.selectWorktreeAtHotkeySlot(index)))
      }
      .appKeyboardShortcut(shortcut)
      .help("Select Worktree \(index + 1) (\(shortcut?.display ?? "no shortcut"))")
    }
  }
}

/// File menu extras (Add Repository / Confirm Action). Split out so the
/// "Worktrees" menu's heavier snapshot dependency doesn't pull this body
/// along on every per-row mutation.
private struct WorktreeFileMenu: Commands {
  @Bindable var store: StoreOf<AppFeature>
  @FocusedValue(\.confirmWorktreeAction) private var confirmWorktreeAction

  var body: some Commands {
    #if DEBUG
      let _: Void = commandsRenderLogger.info("WorktreeFileMenu.body re-rendered")
    #endif
    let overrides = store.worktreeMenuSnapshot.shortcutOverrides
    let openRepo = AppShortcuts.openRepository.effective(from: overrides)
    let addRemoteRepo = AppShortcuts.addRemoteRepository.effective(from: overrides)
    let cloneRepo = AppShortcuts.cloneRepository.effective(from: overrides)
    let confirm = AppShortcuts.confirmWorktreeAction.effective(from: overrides)
    CommandGroup(replacing: .newItem) {
      Menu("Add Repository or Folder", systemImage: "folder.badge.plus") {
        Button("Add Local Repository or Folder...", systemImage: "laptopcomputer") {
          store.send(.repositories(.setOpenPanelPresented(true)))
        }
        .appKeyboardShortcut(openRepo)
        .help("Add a local repository or folder (\(openRepo?.display ?? "none"))")
        Button("Add Remote Repository or Folder...", systemImage: "wifi") {
          store.send(.repositories(.requestAddRemoteRepository))
        }
        .appKeyboardShortcut(addRemoteRepo)
        .help("Add a repository or folder on an SSH host (\(addRemoteRepo?.display ?? "none"))")
        Divider()
        Button("Clone Repository...", systemImage: "square.and.arrow.down.on.square") {
          store.send(.repositories(.requestCloneRepository))
        }
        .appKeyboardShortcut(cloneRepo)
        .help("Clone a remote repository into a local folder (\(cloneRepo?.display ?? "none"))")
      }
      Button("Confirm Action") {
        confirmWorktreeAction?()
      }
      .appKeyboardShortcut(confirm)
      .help("Confirm Action (\(confirm?.display ?? "none"))")
      .disabled(confirmWorktreeAction?.isEnabled != true)
    }
  }
}

/// Stable projection used by the sidebar's slot-to-row resolution.
/// `repositoryName` is carried for any UI that wants to render a repo-aware
/// label without re-pulling whole `repositories` substate observation.
struct HotkeyWorktreeSlot: Equatable, Hashable, Identifiable, Sendable {
  let id: Worktree.ID
  let name: String
  let repositoryID: Repository.ID
  let repositoryName: String
}

private struct ArchiveWorktreeActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct OpenSelectedWorktreeActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct RevealInFinderActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct OpenActionSelectionKey: FocusedValueKey {
  typealias Value = OpenWorktreeAction
}

private struct DeleteWorktreeActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct ConfirmWorktreeActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var openSelectedWorktreeAction: FocusedAction<Void>? {
    get { self[OpenSelectedWorktreeActionKey.self] }
    set { self[OpenSelectedWorktreeActionKey.self] = newValue }
  }

  var revealInFinderAction: FocusedAction<Void>? {
    get { self[RevealInFinderActionKey.self] }
    set { self[RevealInFinderActionKey.self] = newValue }
  }

  var openActionSelection: OpenWorktreeAction? {
    get { self[OpenActionSelectionKey.self] }
    set { self[OpenActionSelectionKey.self] = newValue }
  }

  var confirmWorktreeAction: FocusedAction<Void>? {
    get { self[ConfirmWorktreeActionKey.self] }
    set { self[ConfirmWorktreeActionKey.self] = newValue }
  }

  var archiveWorktreeAction: FocusedAction<Void>? {
    get { self[ArchiveWorktreeActionKey.self] }
    set { self[ArchiveWorktreeActionKey.self] = newValue }
  }

  var deleteWorktreeAction: FocusedAction<Void>? {
    get { self[DeleteWorktreeActionKey.self] }
    set { self[DeleteWorktreeActionKey.self] = newValue }
  }

  var runScriptAction: FocusedAction<Void>? {
    get { self[RunScriptActionKey.self] }
    set { self[RunScriptActionKey.self] = newValue }
  }

  var stopRunScriptAction: FocusedAction<Void>? {
    get { self[StopRunScriptActionKey.self] }
    set { self[StopRunScriptActionKey.self] = newValue }
  }
}

private struct RunScriptActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct StopRunScriptActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}
