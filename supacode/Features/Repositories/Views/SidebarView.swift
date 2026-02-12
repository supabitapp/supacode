import ComposableArchitecture
import Sharing
import SwiftUI

struct SidebarView: View {
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  @Shared(.appStorage("sidebarCollapsedRepositoryIDs")) private var collapsedRepositoryIDs: [Repository.ID] = []

  var body: some View {
    let state = store.state
    let repositoryIDs = Set(state.repositories.map(\.id))
    let pendingRepositoryIDs = Set(state.pendingWorktrees.map(\.repositoryID))
    let collapsedSet = Set(collapsedRepositoryIDs).intersection(repositoryIDs)
    let expandedRepoIDs = repositoryIDs.subtracting(collapsedSet).union(pendingRepositoryIDs)
    let expandedRepoIDsBinding = Binding<Set<Repository.ID>>(
      get: {
        expandedRepoIDs
      },
      set: { newValue in
        let collapsed = repositoryIDs.subtracting(newValue)
        $collapsedRepositoryIDs.withLock {
          $0 = Array(collapsed).sorted()
        }
      }
    )
    let visibleHotkeyRows = state.orderedWorktreeRows(includingRepositoryIDs: expandedRepoIDs)
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
    SidebarListView(store: store, expandedRepoIDs: expandedRepoIDsBinding, terminalManager: terminalManager)
      .focusedSceneValue(\.confirmWorktreeAction, confirmWorktreeAction)
      .focusedSceneValue(\.archiveWorktreeAction, archiveWorktreeAction)
      .focusedSceneValue(\.deleteWorktreeAction, deleteWorktreeAction)
      .focusedSceneValue(\.visibleHotkeyWorktreeRows, visibleHotkeyRows)
      .onChange(of: repositoryIDs) { _, newValue in
        let collapsed = Set(collapsedRepositoryIDs).intersection(newValue)
        $collapsedRepositoryIDs.withLock {
          $0 = Array(collapsed).sorted()
        }
      }
  }
}
