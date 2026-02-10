import ComposableArchitecture
import Foundation

@Reducer
struct DiffFeature {
  @ObservableState
  struct State: Equatable {
    var isPanelVisible = false
    var selectedFilePath: String?
    var entriesByWorktreeID: [Worktree.ID: [GitDiffEntry]] = [:]
    var isLoadingByWorktreeID: [Worktree.ID: Bool] = [:]
  }

  enum Action {
    case togglePanel
    case setPanelVisible(Bool)
    case selectFile(String?)
    case diffEvent(DiffClient.Event)
  }

  @Dependency(\.diffClient) private var diffClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .togglePanel:
        state.isPanelVisible.toggle()
        let visible = state.isPanelVisible
        return .run { _ in
          await diffClient.send(.setPanelVisible(visible))
        }

      case .setPanelVisible(let visible):
        state.isPanelVisible = visible
        return .run { _ in
          await diffClient.send(.setPanelVisible(visible))
        }

      case .selectFile(let path):
        state.selectedFilePath = path
        return .none

      case .diffEvent(.entriesChanged(let worktreeID, let entries)):
        state.entriesByWorktreeID[worktreeID] = entries
        return .none

      case .diffEvent(.loadingChanged(let worktreeID, let isLoading)):
        if isLoading {
          state.isLoadingByWorktreeID[worktreeID] = true
        } else {
          state.isLoadingByWorktreeID.removeValue(forKey: worktreeID)
        }
        return .none
      }
    }
  }
}
