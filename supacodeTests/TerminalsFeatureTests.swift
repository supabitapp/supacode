import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
struct TerminalsFeatureTests {
  @Test func tabProjectionChangedInsertsNewTabThenForwards() async {
    let tabID = UUID()
    let surface = UUID()
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    store.exhaustivity = .off

    await store.send(
      .tabProjectionChanged(
        worktreeID: "/tmp/repo",
        projection: WorktreeTabProjection(
          tabID: TerminalTabID(rawValue: tabID),
          surfaceIDs: [surface],
          activeSurfaceID: surface,
          unseenNotificationCount: 0
        )
      )
    ) {
      $0.terminalTabs.append(
        TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repo")
      )
    }
    await store.receive(\.terminalTabs)
  }

  @Test func tabRemovedDropsElementAndRecordsForReplayProtection() async {
    let tabID = UUID()
    var initial = TerminalsFeature.State()
    initial.terminalTabs.append(
      TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repo")
    )
    let store = TestStore(initialState: initial) { TerminalsFeature() }

    await store.send(.tabRemoved(tabID: TerminalTabID(rawValue: tabID))) {
      $0.terminalTabs.remove(id: tabID)
      $0.recentlyRemovedTabIDs = [tabID]
    }
  }

  @Test func staleTabProjectionAfterRemoveDoesNotReinsertPhantomTab() async {
    let tabID = UUID()
    var initial = TerminalsFeature.State()
    initial.terminalTabs.append(
      TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repo")
    )
    let store = TestStore(initialState: initial) { TerminalsFeature() }

    await store.send(.tabRemoved(tabID: TerminalTabID(rawValue: tabID))) {
      $0.terminalTabs.remove(id: tabID)
      $0.recentlyRemovedTabIDs = [tabID]
    }

    // Late projection arrives after the tab was removed: must NOT re-insert.
    await store.send(
      .tabProjectionChanged(
        worktreeID: "/tmp/repo",
        projection: WorktreeTabProjection(
          tabID: TerminalTabID(rawValue: tabID),
          surfaceIDs: [],
          activeSurfaceID: nil,
          unseenNotificationCount: 0
        )
      )
    )

    #expect(store.state.terminalTabs.isEmpty)
  }

  @Test func recentlyRemovedTabIDsAreBoundedByLimit() async {
    var initial = TerminalsFeature.State()
    let store = TestStore(initialState: initial) { TerminalsFeature() }
    _ = initial

    // Remove `limit + 5` distinct tab IDs; only the most recent `limit` survive.
    let limit = TerminalsFeature.recentlyRemovedTabLimit
    var allIDs: [UUID] = []
    for _ in 0..<(limit + 5) {
      let id = UUID()
      allIDs.append(id)
      await store.send(.tabRemoved(tabID: TerminalTabID(rawValue: id))) {
        $0.recentlyRemovedTabIDs.append(id)
        if $0.recentlyRemovedTabIDs.count > limit {
          $0.recentlyRemovedTabIDs.removeFirst($0.recentlyRemovedTabIDs.count - limit)
        }
      }
    }
    #expect(store.state.recentlyRemovedTabIDs.count == limit)
    #expect(store.state.recentlyRemovedTabIDs.first == allIDs[5])
    #expect(store.state.recentlyRemovedTabIDs.last == allIDs.last)
  }
}
