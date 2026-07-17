import ComposableArchitecture
import Foundation

/// Owns the collection of per-tab `TerminalTabFeature` states. Mirrors the
/// sidebar's `RepositoriesFeature` ownership of `sidebarItems`. Views scope
/// through `store.scope(state: \.terminals, action: \.terminals)` so tab-bar
/// surface area stays bounded to terminal state instead of the whole app.
@Reducer
struct TerminalsFeature {
  /// Bounded recent-removal memory. A late `tabProjectionChanged` emit landing
  /// after `tabRemoved` would otherwise re-insert a phantom tab; tracking the
  /// most recent removals lets the reducer drop those stragglers.
  static let recentlyRemovedTabLimit = 128

  /// Removed-tab record keyed by `(worktreeID, tabID)`. Same-session
  /// snapshot-restore reuses the persisted `tabSnapshot.id`, so scoping the
  /// dedup by worktree lets the FIFO drain when its owning worktree's state
  /// is torn down without shadowing a legitimate re-add.
  struct RecentlyRemovedTab: Equatable, Sendable {
    let worktreeID: Worktree.ID
    let tabID: TerminalTabID
  }

  @ObservableState
  struct State: Equatable {
    /// Per-tab feature instances keyed by `TerminalTabID`. Tab-bar leaves
    /// scope through `\.terminalTabs[id:]` for per-tab observation isolation
    /// during agent storms.
    var terminalTabs: IdentifiedArrayOf<TerminalTabFeature.State> = []
    /// FIFO of recently-removed tabs scoped by `(worktreeID, tabID)`. Insert
    /// order = removal order; oldest entry is dropped when the cap is hit.
    var recentlyRemovedTabIDs: [RecentlyRemovedTab] = []
  }

  enum Action {
    case terminalTabs(IdentifiedActionOf<TerminalTabFeature>)
    /// Tab projection arrived from `WorktreeTerminalState`. Inserts a new
    /// per-tab state with its current agent snapshot if missing, then forwards
    /// the projection to the tab's reducer.
    case tabProjectionChanged(
      worktreeID: Worktree.ID,
      projection: WorktreeTabProjection,
      initialAgentSnapshot: AgentPresenceFeature.RowSnapshot
    )
    /// Tab destroyed in the worktree state. Drops the matching feature state.
    case tabRemoved(worktreeID: Worktree.ID, tabID: TerminalTabID)
    /// Worktree's entire terminal state was torn down (prune path). Drops any
    /// orphan `terminalTabs` rows and removed-tab FIFO records for this
    /// worktree so a same-session re-attach starts clean.
    case worktreeStateTornDown(worktreeID: Worktree.ID)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .terminalTabs:
        return .none

      case .tabProjectionChanged(let worktreeID, let projection, let initialAgentSnapshot):
        let tabID = projection.tabID
        if state.terminalTabs[id: tabID] == nil {
          // Drop stale projections arriving after the tab was removed in this
          // worktree. Matching by (worktreeID, tabID) so a snapshot-restore
          // under a different worktree wouldn't be shadowed; the per-worktree
          // drain on teardown covers the same-worktree restore case.
          guard
            !state.recentlyRemovedTabIDs.contains(where: {
              $0.worktreeID == worktreeID && $0.tabID == tabID
            })
          else { return .none }
          state.terminalTabs.append(
            TerminalTabFeature.State(
              id: tabID,
              worktreeID: worktreeID,
              agentSnapshot: initialAgentSnapshot
            )
          )
        }
        return .send(.terminalTabs(.element(id: tabID, action: .projectionChanged(projection))))

      case .tabRemoved(let worktreeID, let tabID):
        state.terminalTabs.remove(id: tabID)
        state.recentlyRemovedTabIDs.append(
          RecentlyRemovedTab(worktreeID: worktreeID, tabID: tabID)
        )
        if state.recentlyRemovedTabIDs.count > Self.recentlyRemovedTabLimit {
          state.recentlyRemovedTabIDs.removeFirst(
            state.recentlyRemovedTabIDs.count - Self.recentlyRemovedTabLimit
          )
        }
        return .none

      case .worktreeStateTornDown(let worktreeID):
        state.recentlyRemovedTabIDs.removeAll { $0.worktreeID == worktreeID }
        state.terminalTabs.removeAll { $0.worktreeID == worktreeID }
        return .none
      }
    }
    .forEach(\.terminalTabs, action: \.terminalTabs) {
      TerminalTabFeature()
    }
  }
}
