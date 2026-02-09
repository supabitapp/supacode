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
    let selectedRow = state.selectedRow(for: state.selectedWorktreeID)
    let confirmWorktreeAction: (() -> Void)? = {
      guard let alert = state.confirmWorktreeAlert else { return nil }
      return {
        store.send(.alert(.presented(alert)))
      }
    }()
    let archiveWorktreeAction: (() -> Void)? = {
      if let selectedRow, selectedRow.isRemovable, !selectedRow.isMainWorktree {
        return {
          store.send(.requestArchiveWorktree(selectedRow.id, selectedRow.repositoryID))
        }
      }
      if let selectedTask = state.selectedTask {
        return {
          store.send(.archiveTask(selectedTask.id))
        }
      }
      return nil
    }()
    let deleteWorktreeAction: (() -> Void)? = {
      if let selectedRow, selectedRow.isRemovable {
        return {
          store.send(.requestDeleteWorktree(selectedRow.id, selectedRow.repositoryID))
        }
      }
      if let selectedTask = state.selectedTask {
        return {
          store.send(.requestDeleteTask(selectedTask.id, selectedTask.repositoryID))
        }
      }
      return nil
    }()
    SidebarListView(store: store, expandedRepoIDs: $expandedRepoIDs, terminalManager: terminalManager)
      .focusedSceneValue(\.confirmWorktreeAction, confirmWorktreeAction)
      .focusedSceneValue(\.archiveWorktreeAction, archiveWorktreeAction)
      .focusedSceneValue(\.deleteWorktreeAction, deleteWorktreeAction)
  }
}
