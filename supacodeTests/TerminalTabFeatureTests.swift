import ComposableArchitecture
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct TerminalTabFeatureTests {
  @Test func projectionChangedShortCircuitsOnEqualPayload() async {
    let tabID = TerminalTabID(rawValue: UUID())
    let initial = TerminalTabFeature.State(
      id: tabID,
      worktreeID: "/tmp/repo",
      surfaceIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000000001")!],
      activeSurfaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      unseenNotificationCount: 0
    )
    let store = TestStore(initialState: initial) { TerminalTabFeature() }

    // Same fields back-in: reducer must mutate nothing.
    await store.send(
      .projectionChanged(
        WorktreeTabProjection(
          tabID: tabID,
          surfaceIDs: initial.surfaceIDs,
          activeSurfaceID: initial.activeSurfaceID,
          unseenNotificationCount: 0
        )
      ))
  }

  @Test func projectionChangedAppliesEachFieldIndependently() async {
    let tabID = TerminalTabID(rawValue: UUID())
    let store = TestStore(
      initialState: TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repo")
    ) { TerminalTabFeature() }

    let surface = UUID()
    await store.send(
      .projectionChanged(
        WorktreeTabProjection(
          tabID: tabID,
          surfaceIDs: [surface],
          activeSurfaceID: surface,
          unseenNotificationCount: 3,
          isSplitZoomed: true
        )
      )
    ) {
      $0.surfaceIDs = [surface]
      $0.activeSurfaceID = surface
      $0.unseenNotificationCount = 3
      $0.isSplitZoomed = true
    }
  }

  @Test func projectionChangedTogglesSplitZoomedIndependently() async {
    let tabID = TerminalTabID(rawValue: UUID())
    let surface = UUID()
    let store = TestStore(
      initialState: TerminalTabFeature.State(
        id: tabID,
        worktreeID: "/tmp/repo",
        surfaceIDs: [surface],
        activeSurfaceID: surface,
        unseenNotificationCount: 0,
        isSplitZoomed: true
      )
    ) { TerminalTabFeature() }

    await store.send(
      .projectionChanged(
        WorktreeTabProjection(
          tabID: tabID,
          surfaceIDs: [surface],
          activeSurfaceID: surface,
          unseenNotificationCount: 0,
          isSplitZoomed: false
        )
      )
    ) {
      $0.isSplitZoomed = false
    }
  }

  @Test func agentSnapshotChangedShortCircuitsOnEqualArray() async {
    let tabID = TerminalTabID(rawValue: UUID())
    let agents = [
      AgentPresenceFeature.AgentInstance(agent: .claude, activity: .busy)
    ]
    let store = TestStore(
      initialState: TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repo", agents: agents)
    ) { TerminalTabFeature() }

    await store.send(.agentSnapshotChanged(agents))
  }

  @Test func agentSnapshotChangedReplacesArrayOnDiff() async {
    let tabID = TerminalTabID(rawValue: UUID())
    let store = TestStore(
      initialState: TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repo")
    ) { TerminalTabFeature() }
    let agents = [
      AgentPresenceFeature.AgentInstance(agent: .codex, activity: .idle)
    ]

    await store.send(.agentSnapshotChanged(agents)) {
      $0.agents = agents
    }
  }

  @Test func progressDisplayChangedShortCircuitsOnEqualDisplay() async {
    let tabID = TerminalTabID(rawValue: UUID())
    let display = TerminalTabProgressDisplay(style: .indeterminate)
    let store = TestStore(
      initialState: TerminalTabFeature.State(
        id: tabID, worktreeID: "/tmp/repo", progressDisplay: display
      )
    ) { TerminalTabFeature() }

    await store.send(.progressDisplayChanged(display))
  }

  @Test func progressDisplayChangedClearsToNil() async {
    let tabID = TerminalTabID(rawValue: UUID())
    let store = TestStore(
      initialState: TerminalTabFeature.State(
        id: tabID, worktreeID: "/tmp/repo",
        progressDisplay: TerminalTabProgressDisplay(style: .determinate(percent: 50))
      )
    ) { TerminalTabFeature() }

    await store.send(.progressDisplayChanged(nil)) {
      $0.progressDisplay = nil
    }
  }
}
