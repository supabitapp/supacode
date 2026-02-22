import AppKit
import ComposableArchitecture
import Sharing
import SwiftUI

struct WorktreeCommands: Commands {
  @Bindable var store: StoreOf<AppFeature>
  @FocusedValue(\.openSelectedWorktreeAction) private var openSelectedWorktreeAction
  @FocusedValue(\.confirmWorktreeAction) private var confirmWorktreeAction
  @FocusedValue(\.archiveWorktreeAction) private var archiveWorktreeAction
  @FocusedValue(\.deleteWorktreeAction) private var deleteWorktreeAction
  @FocusedValue(\.runScriptAction) private var runScriptAction
  @FocusedValue(\.stopRunScriptAction) private var stopRunScriptAction
  @FocusedValue(\.visibleHotkeyWorktreeRows) private var visibleHotkeyWorktreeRows
  @Shared(.settingsFile) private var settingsFile

  init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  var body: some Commands {
    let globalSettings = settingsFile.global
    let repositories = store.repositories
    let orderedRows = visibleHotkeyWorktreeRows ?? repositories.orderedWorktreeRows()
    let pullRequestURL = selectedPullRequestURL
    let githubIntegrationEnabled = store.settings.githubIntegrationEnabled
    let archiveShortcut = KeyboardShortcut(.delete, modifiers: .command).display
    let deleteShortcut = KeyboardShortcut(.delete, modifiers: [.command, .shift]).display
    let selectNext = AppShortcuts.selectNextWorktree.effective(from: globalSettings)
    let selectPrevious = AppShortcuts.selectPreviousWorktree.effective(from: globalSettings)
    let openRepo = AppShortcuts.openRepository.effective(from: globalSettings)
    let openWorktree = AppShortcuts.openFinder.effective(from: globalSettings)
    let openPR = AppShortcuts.openPullRequest.effective(from: globalSettings)
    let newWt = AppShortcuts.newWorktree.effective(from: globalSettings)
    let archived = AppShortcuts.archivedWorktrees.effective(from: globalSettings)
    let refresh = AppShortcuts.refreshWorktrees.effective(from: globalSettings)
    let run = AppShortcuts.runScript.effective(from: globalSettings)
    let stop = AppShortcuts.stopRunScript.effective(from: globalSettings)
    CommandMenu("Worktrees") {
      Button("Select Next Worktree") {
        store.send(.repositories(.selectNextWorktree))
      }
      .keyboardShortcut(
        selectNext.keyEquivalent,
        modifiers: selectNext.modifiers
      )
      .help("Select Next Worktree (\(selectNext.display))")
      .disabled(orderedRows.isEmpty)
      Button("Select Previous Worktree") {
        store.send(.repositories(.selectPreviousWorktree))
      }
      .keyboardShortcut(
        selectPrevious.keyEquivalent,
        modifiers: selectPrevious.modifiers
      )
      .help("Select Previous Worktree (\(selectPrevious.display))")
      .disabled(orderedRows.isEmpty)
      Divider()
      ForEach(worktreeShortcuts(from: globalSettings).indices, id: \.self) { index in
        let shortcut = worktreeShortcuts(from: globalSettings)[index]
        worktreeShortcutButton(index: index, shortcut: shortcut, orderedRows: orderedRows)
      }
    }
    CommandGroup(replacing: .newItem) {
      Button("Open Repository...", systemImage: "folder") {
        store.send(.repositories(.setOpenPanelPresented(true)))
      }
      .keyboardShortcut(
        openRepo.keyEquivalent,
        modifiers: openRepo.modifiers
      )
      .help("Open Repository (\(openRepo.display))")
      Button("Open Worktree") {
        openSelectedWorktreeAction?()
      }
      .keyboardShortcut(
        openWorktree.keyEquivalent,
        modifiers: openWorktree.modifiers
      )
      .help("Open Worktree (\(openWorktree.display))")
      .disabled(openSelectedWorktreeAction == nil)
      Button("Open Pull Request on GitHub") {
        if let pullRequestURL {
          NSWorkspace.shared.open(pullRequestURL)
        }
      }
      .keyboardShortcut(
        openPR.keyEquivalent,
        modifiers: openPR.modifiers
      )
      .help("Open Pull Request on GitHub (\(openPR.display))")
      .disabled(pullRequestURL == nil || !githubIntegrationEnabled)
      Button("New Worktree", systemImage: "plus") {
        store.send(.repositories(.createRandomWorktree))
      }
      .keyboardShortcut(
        newWt.keyEquivalent, modifiers: newWt.modifiers
      )
      .help("New Worktree (\(newWt.display))")
      .disabled(!repositories.canCreateWorktree)
      Button("Archived Worktrees") {
        store.send(.repositories(.selectArchivedWorktrees))
      }
      .keyboardShortcut(
        archived.keyEquivalent,
        modifiers: archived.modifiers
      )
      .help("Archived Worktrees (\(archived.display))")
      Button("Archive Worktree") {
        archiveWorktreeAction?()
      }
      .keyboardShortcut(.delete, modifiers: .command)
      .help("Archive Worktree (\(archiveShortcut))")
      .disabled(archiveWorktreeAction == nil)
      Button("Delete Worktree") {
        deleteWorktreeAction?()
      }
      .keyboardShortcut(.delete, modifiers: [.command, .shift])
      .help("Delete Worktree (\(deleteShortcut))")
      .disabled(deleteWorktreeAction == nil)
      Button("Confirm Worktree Action") {
        confirmWorktreeAction?()
      }
      .keyboardShortcut(.return, modifiers: .command)
      .help("Confirm Worktree Action (⌘↩)")
      .disabled(confirmWorktreeAction == nil)
      Button("Refresh Worktrees") {
        store.send(.repositories(.refreshWorktrees))
      }
      .keyboardShortcut(
        refresh.keyEquivalent,
        modifiers: refresh.modifiers
      )
      .help("Refresh Worktrees (\(refresh.display))")
      Divider()
      Button("Run Script") {
        runScriptAction?()
      }
      .keyboardShortcut(
        run.keyEquivalent,
        modifiers: run.modifiers
      )
      .help("Run Script (\(run.display))")
      .disabled(runScriptAction == nil)
      Button("Stop Script") {
        stopRunScriptAction?()
      }
      .keyboardShortcut(
        stop.keyEquivalent,
        modifiers: stop.modifiers
      )
      .help("Stop Script (\(stop.display))")
      .disabled(stopRunScriptAction == nil)
    }
  }

  private func worktreeShortcuts(from settings: GlobalSettings) -> [AppShortcut] {
    AppShortcuts.worktreeSelection.map { $0.effective(from: settings) }
  }

  private var selectedPullRequestURL: URL? {
    let repositories = store.repositories
    guard let selectedWorktreeID = repositories.selectedWorktreeID else { return nil }
    let pullRequest = repositories.worktreeInfoByID[selectedWorktreeID]?.pullRequest
    return pullRequest.flatMap { URL(string: $0.url) }
  }

  private func worktreeShortcutButton(
    index: Int,
    shortcut: AppShortcut,
    orderedRows: [WorktreeRowModel]
  ) -> some View {
    let row = orderedRows.indices.contains(index) ? orderedRows[index] : nil
    let title = worktreeShortcutTitle(index: index, row: row)
    return Button(title) {
      guard let row else { return }
      store.send(.repositories(.selectWorktree(row.id)))
    }
    .keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.modifiers)
    .help("Switch to \(title) (\(shortcut.display))")
    .disabled(row == nil)
  }

  private func worktreeShortcutTitle(index: Int, row: WorktreeRowModel?) -> String {
    guard let row else { return "Worktree \(index + 1)" }
    let repositoryName = store.repositories.repositoryName(for: row.repositoryID) ?? "Repository"
    return "\(repositoryName) — \(row.name)"
  }
}

private struct ArchiveWorktreeActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct OpenSelectedWorktreeActionKey: FocusedValueKey {
  typealias Value = () -> Void
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

  var visibleHotkeyWorktreeRows: [WorktreeRowModel]? {
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
  typealias Value = [WorktreeRowModel]
}
