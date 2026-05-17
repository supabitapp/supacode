import ComposableArchitecture
import Foundation

/// Owns the collection of per-tab `TerminalTabFeature` states. Mirrors the
/// sidebar's `RepositoriesFeature` ownership of `sidebarItems`. Views scope
/// through `store.scope(state: \.terminals, action: \.terminals)` so tab-bar
/// surface area stays bounded to terminal state instead of the whole app.
@Reducer
struct TerminalsFeature {
  @ObservableState
  struct State: Equatable {
    /// Per-tab feature instances keyed by `TerminalTabID.rawValue` (UUID).
    /// Tab-bar leaves scope through `\.terminalTabs[id:]` for per-tab
    /// observation isolation during agent storms.
    var terminalTabs: IdentifiedArrayOf<TerminalTabFeature.State> = []
  }

  enum Action {
    case terminalTabs(IdentifiedActionOf<TerminalTabFeature>)
    /// Tab projection arrived from `WorktreeTerminalState`. Inserts a new
    /// per-tab state if missing, then forwards to the tab's reducer.
    case tabProjectionChanged(worktreeID: Worktree.ID, projection: WorktreeTabProjection)
    /// Tab destroyed in the worktree state. Drops the matching feature state.
    case tabRemoved(tabID: TerminalTabID)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .terminalTabs:
        return .none

      case .tabProjectionChanged(let worktreeID, let projection):
        let elementID = projection.tabID.rawValue
        if state.terminalTabs[id: elementID] == nil {
          state.terminalTabs.append(
            TerminalTabFeature.State(id: elementID, worktreeID: worktreeID)
          )
        }
        return .send(.terminalTabs(.element(id: elementID, action: .projectionChanged(projection))))

      case .tabRemoved(let tabID):
        state.terminalTabs.remove(id: tabID.rawValue)
        return .none
      }
    }
    .forEach(\.terminalTabs, action: \.terminalTabs) {
      TerminalTabFeature()
    }
  }
}
