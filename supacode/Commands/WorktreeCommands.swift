import AppKit
import ComposableArchitecture
import SwiftUI

struct WorktreeCommands: Commands {
  @Bindable var store: StoreOf<AppFeature>
  @FocusedValue(\.openSelectedWorktreeAction) private var openSelectedWorktreeAction
  @FocusedValue(\.confirmWorktreeAction) private var confirmWorktreeAction
  @FocusedValue(\.archiveWorktreeAction) private var archiveWorktreeAction
  @FocusedValue(\.deleteWorktreeAction) private var deleteWorktreeAction
  @FocusedValue(\.runScriptAction) private var runScriptAction
  @FocusedValue(\.stopRunScriptAction) private var stopRunScriptAction
  @FocusedValue(\.sidebarHotkeyTargets) private var sidebarHotkeyTargets
  @FocusedValue(\.executeSidebarHotkeyTargetAction) private var executeSidebarHotkeyTargetAction

  init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  var body: some Commands {
    let repositories = store.repositories
    let hotkeyTargets = worktreeHotkeyTargets
    let pullRequestURL = selectedPullRequestURL
    let githubIntegrationEnabled = store.settings.githubIntegrationEnabled
    let archiveShortcut = KeyboardShortcut(.delete, modifiers: .command).display
    let deleteShortcut = KeyboardShortcut(.delete, modifiers: [.command, .shift]).display
    CommandMenu("Worktrees") {
      ForEach(worktreeShortcuts.indices, id: \.self) { index in
        let shortcut = worktreeShortcuts[index]
        worktreeShortcutButton(index: index, shortcut: shortcut, hotkeyTargets: hotkeyTargets)
      }
    }
    CommandGroup(replacing: .newItem) {
      Button("Open Repository...", systemImage: "folder") {
        store.send(.repositories(.setOpenPanelPresented(true)))
      }
      .keyboardShortcut(
        AppShortcuts.openRepository.keyEquivalent,
        modifiers: AppShortcuts.openRepository.modifiers
      )
      .help("Open Repository (\(AppShortcuts.openRepository.display))")
      Button("Open Worktree") {
        openSelectedWorktreeAction?()
      }
      .keyboardShortcut(
        AppShortcuts.openFinder.keyEquivalent,
        modifiers: AppShortcuts.openFinder.modifiers
      )
      .help("Open Worktree (\(AppShortcuts.openFinder.display))")
      .disabled(openSelectedWorktreeAction == nil)
      Button("Open Pull Request on GitHub") {
        if let pullRequestURL {
          NSWorkspace.shared.open(pullRequestURL)
        }
      }
      .keyboardShortcut(
        AppShortcuts.openPullRequest.keyEquivalent,
        modifiers: AppShortcuts.openPullRequest.modifiers
      )
      .help("Open Pull Request on GitHub (\(AppShortcuts.openPullRequest.display))")
      .disabled(pullRequestURL == nil || !githubIntegrationEnabled)
      Button("New Worktree", systemImage: "plus") {
        store.send(.repositories(.createRandomWorktree))
      }
      .keyboardShortcut(
        AppShortcuts.newWorktree.keyEquivalent, modifiers: AppShortcuts.newWorktree.modifiers
      )
      .help("New Worktree (\(AppShortcuts.newWorktree.display))")
      .disabled(!repositories.canCreateWorktree)
      Button("Archived Worktrees") {
        store.send(.repositories(.selectArchivedWorktrees))
      }
      .keyboardShortcut(
        AppShortcuts.archivedWorktrees.keyEquivalent,
        modifiers: AppShortcuts.archivedWorktrees.modifiers
      )
      .help("Archived Worktrees (\(AppShortcuts.archivedWorktrees.display))")
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
        AppShortcuts.refreshWorktrees.keyEquivalent,
        modifiers: AppShortcuts.refreshWorktrees.modifiers
      )
      .help("Refresh Worktrees (\(AppShortcuts.refreshWorktrees.display))")
      Divider()
      Button("Run Script") {
        runScriptAction?()
      }
      .keyboardShortcut(
        AppShortcuts.runScript.keyEquivalent,
        modifiers: AppShortcuts.runScript.modifiers
      )
      .help("Run Script (\(AppShortcuts.runScript.display))")
      .disabled(runScriptAction == nil)
      Button("Stop Script") {
        stopRunScriptAction?()
      }
      .keyboardShortcut(
        AppShortcuts.stopRunScript.keyEquivalent,
        modifiers: AppShortcuts.stopRunScript.modifiers
      )
      .help("Stop Script (\(AppShortcuts.stopRunScript.display))")
      .disabled(stopRunScriptAction == nil)
    }
  }

  private var worktreeShortcuts: [AppShortcut] {
    AppShortcuts.worktreeSelection
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
    hotkeyTargets: [SidebarHotkeyTarget]
  ) -> some View {
    let target = hotkeyTargets.indices.contains(index) ? hotkeyTargets[index] : nil
    let title = worktreeShortcutTitle(index: index, target: target)
    return Button(title) {
      guard let target else { return }
      if let executeSidebarHotkeyTargetAction {
        executeSidebarHotkeyTargetAction(index)
        return
      }
      if case .worktree(let worktreeID, _, _, _) = target {
        store.send(.repositories(.selectWorktree(worktreeID)))
      }
    }
    .keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.modifiers)
    .help("Switch to \(title) (\(shortcut.display))")
    .disabled(target == nil)
  }

  private func worktreeShortcutTitle(index: Int, target: SidebarHotkeyTarget?) -> String {
    guard let target else { return "Worktree \(index + 1)" }
    return target.title
  }

  private var worktreeHotkeyTargets: [SidebarHotkeyTarget] {
    if let sidebarHotkeyTargets {
      return Array(sidebarHotkeyTargets.prefix(worktreeShortcuts.count))
    }
    let orderedRows = store.repositories.orderedWorktreeRows()
    return orderedRows.prefix(worktreeShortcuts.count).map { row in
      let repositoryName = store.repositories.repositoryName(for: row.repositoryID) ?? "Repository"
      return .worktree(
        id: row.id,
        repositoryID: row.repositoryID,
        repositoryName: repositoryName,
        worktreeName: row.name
      )
    }
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

  var sidebarHotkeyTargets: [SidebarHotkeyTarget]? {
    get { self[SidebarHotkeyTargetsKey.self] }
    set { self[SidebarHotkeyTargetsKey.self] = newValue }
  }

  var executeSidebarHotkeyTargetAction: ((Int) -> Void)? {
    get { self[ExecuteSidebarHotkeyTargetActionKey.self] }
    set { self[ExecuteSidebarHotkeyTargetActionKey.self] = newValue }
  }
}

private struct RunScriptActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct StopRunScriptActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

private struct SidebarHotkeyTargetsKey: FocusedValueKey {
  typealias Value = [SidebarHotkeyTarget]
}

private struct ExecuteSidebarHotkeyTargetActionKey: FocusedValueKey {
  typealias Value = (Int) -> Void
}
