import ComposableArchitecture
import SwiftUI

struct SidebarView: View {
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @State private var expandedRepoIDs: Set<Repository.ID>

  init(store: StoreOf<RepositoriesFeature>, terminalManager: WorktreeTerminalManager) {
    self.store = store
    self.terminalManager = terminalManager
    let repositoryIDs = Set(store.repositories.map(\.id))
    let pendingRepositoryIDs = Set(store.pendingWorktrees.map(\.repositoryID))
    _expandedRepoIDs = State(initialValue: repositoryIDs.union(pendingRepositoryIDs))
  }

  var body: some View {
    let state = store.state
    let hotkeyTargets = state.sidebarHotkeyTargets(expandedRepoIDs: expandedRepoIDs)
    let cappedHotkeyTargets = Array(hotkeyTargets.prefix(AppShortcuts.worktreeSelection.count))
    let repoShortcutIndexByID: [Repository.ID: Int] = Dictionary(
      uniqueKeysWithValues: cappedHotkeyTargets.enumerated().compactMap { index, target in
        guard case .repository(let repositoryID, _) = target else { return nil }
        return (repositoryID, index)
      }
    )
    let worktreeShortcutIndexByID: [Worktree.ID: Int] = Dictionary(
      uniqueKeysWithValues: cappedHotkeyTargets.enumerated().compactMap { index, target in
        guard case .worktree(let worktreeID, _, _, _) = target else { return nil }
        return (worktreeID, index)
      }
    )
    let selectedRow = state.selectedRow(for: state.selectedWorktreeID)
    let confirmWorktreeAction: (() -> Void)? = {
      guard let alert = state.confirmWorktreeAlert else { return nil }
      return {
        store.send(.alert(.presented(alert)))
      }
    }()
    let archiveWorktreeAction: (() -> Void)? = {
      guard let selectedRow, selectedRow.isRemovable, !selectedRow.isMainWorktree else { return nil }
      return {
        store.send(.requestArchiveWorktree(selectedRow.id, selectedRow.repositoryID))
      }
    }()
    let deleteWorktreeAction: (() -> Void)? = {
      guard let selectedRow, selectedRow.isRemovable else { return nil }
      return {
        store.send(.requestDeleteWorktree(selectedRow.id, selectedRow.repositoryID))
      }
    }()
    let executeSidebarHotkeyTargetAction: ((Int) -> Void)? = { index in
      guard cappedHotkeyTargets.indices.contains(index) else { return }
      let target = cappedHotkeyTargets[index]
      switch target {
      case .repository(let repositoryID, _):
        guard let repository = store.state.repositories[id: repositoryID],
          !store.state.isRemovingRepository(repository)
        else { return }
        withAnimation(.easeOut(duration: 0.2)) {
          expandedRepoIDs.insert(repositoryID)
        }
      case .worktree(let worktreeID, _, _, _):
        store.send(.selectWorktree(worktreeID))
      }
    }
    SidebarListView(
      store: store,
      expandedRepoIDs: $expandedRepoIDs,
      repoShortcutIndexByID: repoShortcutIndexByID,
      worktreeShortcutIndexByID: worktreeShortcutIndexByID,
      terminalManager: terminalManager
    )
    .focusedSceneValue(\.confirmWorktreeAction, confirmWorktreeAction)
    .focusedSceneValue(\.archiveWorktreeAction, archiveWorktreeAction)
    .focusedSceneValue(\.deleteWorktreeAction, deleteWorktreeAction)
    .focusedSceneValue(\.sidebarHotkeyTargets, cappedHotkeyTargets)
    .focusedSceneValue(\.executeSidebarHotkeyTargetAction, executeSidebarHotkeyTargetAction)
  }
}
