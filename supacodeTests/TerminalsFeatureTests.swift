import ComposableArchitecture
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct TerminalsFeatureTests {
  @Test func tabProjectionChangedInsertsNewTabThenForwards() async {
    let tabID = TerminalTabID(rawValue: UUID())
    let surface = UUID()
    let agentSnapshot = AgentPresenceFeature.RowSnapshot(
      agents: [.init(agent: .claude, activity: .busy)],
      isWorking: true
    )
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    store.exhaustivity = .off

    await store.send(
      .tabProjectionChanged(
        worktreeID: "/tmp/repo",
        projection: WorktreeTabProjection(
          tabID: tabID,
          surfaceIDs: [surface],
          activeSurfaceID: surface,
          unseenNotificationCount: 0
        ),
        initialAgentSnapshot: agentSnapshot
      )
    ) {
      $0.terminalTabs.append(
        TerminalTabFeature.State(
          id: tabID,
          worktreeID: "/tmp/repo",
          agentSnapshot: agentSnapshot
        )
      )
    }
    await store.receive(\.terminalTabs)
  }

  @Test func tabRemovedDropsElementAndRecordsForReplayProtection() async {
    let tabID = TerminalTabID(rawValue: UUID())
    var initial = TerminalsFeature.State()
    initial.terminalTabs.append(
      TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repo")
    )
    let store = TestStore(initialState: initial) { TerminalsFeature() }

    await store.send(.tabRemoved(worktreeID: "/tmp/repo", tabID: tabID)) {
      $0.terminalTabs.remove(id: tabID)
      $0.recentlyRemovedTabIDs = [
        TerminalsFeature.RecentlyRemovedTab(worktreeID: "/tmp/repo", tabID: tabID)
      ]
    }
  }

  @Test func staleTabProjectionAfterRemoveDoesNotReinsertPhantomTab() async {
    let tabID = TerminalTabID(rawValue: UUID())
    var initial = TerminalsFeature.State()
    initial.terminalTabs.append(
      TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repo")
    )
    let store = TestStore(initialState: initial) { TerminalsFeature() }

    await store.send(.tabRemoved(worktreeID: "/tmp/repo", tabID: tabID)) {
      $0.terminalTabs.remove(id: tabID)
      $0.recentlyRemovedTabIDs = [
        TerminalsFeature.RecentlyRemovedTab(worktreeID: "/tmp/repo", tabID: tabID)
      ]
    }

    // Late projection arrives after the tab was removed in the same worktree: must NOT re-insert.
    await store.send(
      .tabProjectionChanged(
        worktreeID: "/tmp/repo",
        projection: WorktreeTabProjection(
          tabID: tabID,
          surfaceIDs: [],
          activeSurfaceID: nil,
          unseenNotificationCount: 0
        ),
        initialAgentSnapshot: .init()
      )
    )

    #expect(store.state.terminalTabs.isEmpty)
  }

  @Test func recentlyRemovedTabIDsAreBoundedByLimit() async {
    let initial = TerminalsFeature.State()
    let store = TestStore(initialState: initial) { TerminalsFeature() }

    // Remove `limit + 5` distinct tab IDs; only the most recent `limit` survive.
    let limit = TerminalsFeature.recentlyRemovedTabLimit
    var allIDs: [TerminalTabID] = []
    for _ in 0..<(limit + 5) {
      let id = TerminalTabID(rawValue: UUID())
      allIDs.append(id)
      await store.send(.tabRemoved(worktreeID: "/tmp/repo", tabID: id)) {
        $0.recentlyRemovedTabIDs.append(
          TerminalsFeature.RecentlyRemovedTab(worktreeID: "/tmp/repo", tabID: id)
        )
        if $0.recentlyRemovedTabIDs.count > limit {
          $0.recentlyRemovedTabIDs.removeFirst($0.recentlyRemovedTabIDs.count - limit)
        }
      }
    }
    #expect(store.state.recentlyRemovedTabIDs.count == limit)
    #expect(store.state.recentlyRemovedTabIDs.first?.tabID == allIDs[5])
    #expect(store.state.recentlyRemovedTabIDs.last?.tabID == allIDs.last)
  }

  @Test func worktreeStateTornDownDrainsTabsAndFIFOForThatWorktree() async {
    // Two worktrees, two tabs each. Tearing down repoA should leave repoB's
    // FIFO + tab features intact.
    let tabA1 = TerminalTabID(rawValue: UUID())
    let tabA2 = TerminalTabID(rawValue: UUID())
    let tabB1 = TerminalTabID(rawValue: UUID())
    var initial = TerminalsFeature.State()
    initial.terminalTabs.append(TerminalTabFeature.State(id: tabA1, worktreeID: "/tmp/repoA"))
    initial.terminalTabs.append(TerminalTabFeature.State(id: tabA2, worktreeID: "/tmp/repoA"))
    initial.terminalTabs.append(TerminalTabFeature.State(id: tabB1, worktreeID: "/tmp/repoB"))
    initial.recentlyRemovedTabIDs = [
      TerminalsFeature.RecentlyRemovedTab(
        worktreeID: "/tmp/repoA", tabID: TerminalTabID(rawValue: UUID())),
      TerminalsFeature.RecentlyRemovedTab(
        worktreeID: "/tmp/repoB", tabID: TerminalTabID(rawValue: UUID())),
    ]
    let repoBRecord = initial.recentlyRemovedTabIDs[1]
    let store = TestStore(initialState: initial) { TerminalsFeature() }

    await store.send(.worktreeStateTornDown(worktreeID: "/tmp/repoA")) {
      $0.recentlyRemovedTabIDs = [repoBRecord]
      $0.terminalTabs.remove(id: tabA1)
      $0.terminalTabs.remove(id: tabA2)
    }
  }

  @Test func sameSessionRestoreAfterTeardownReinsertsTabWithReusedUUID() async {
    // Simulates the snapshot-restore path: tab removed in worktree A, worktree
    // state torn down (FIFO drained for worktreeA), restore replays the same
    // persisted UUID. The reinserted projection must not be shadowed.
    let tabID = TerminalTabID(rawValue: UUID())
    var initial = TerminalsFeature.State()
    initial.terminalTabs.append(TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repoA"))
    let store = TestStore(initialState: initial) { TerminalsFeature() }
    store.exhaustivity = .off

    await store.send(.tabRemoved(worktreeID: "/tmp/repoA", tabID: tabID)) {
      $0.terminalTabs.remove(id: tabID)
      $0.recentlyRemovedTabIDs = [
        TerminalsFeature.RecentlyRemovedTab(worktreeID: "/tmp/repoA", tabID: tabID)
      ]
    }

    await store.send(.worktreeStateTornDown(worktreeID: "/tmp/repoA")) {
      $0.recentlyRemovedTabIDs = []
    }

    let surface = UUID()
    await store.send(
      .tabProjectionChanged(
        worktreeID: "/tmp/repoA",
        projection: WorktreeTabProjection(
          tabID: tabID,
          surfaceIDs: [surface],
          activeSurfaceID: surface,
          unseenNotificationCount: 0
        ),
        initialAgentSnapshot: .init()
      )
    ) {
      $0.terminalTabs.append(TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repoA"))
    }
    await store.receive(\.terminalTabs)
  }
}
