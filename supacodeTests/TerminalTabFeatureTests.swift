import ComposableArchitecture
import Foundation
import GhosttyKit
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
          hasTerminalActivity: true,
          isSplitZoomed: true
        )
      )
    ) {
      $0.surfaceIDs = [surface]
      $0.hasTerminalActivity = true
      $0.activeSurfaceID = surface
      $0.unseenNotificationCount = 3
      $0.isSplitZoomed = true
    }
  }

  @Test func projectionChangedPropagatesSurfaceGeneration() async {
    let tabID = TerminalTabID(rawValue: UUID())
    let surface = UUID()
    let store = TestStore(
      initialState: TerminalTabFeature.State(
        id: tabID,
        worktreeID: "/tmp/repo",
        surfaceIDs: [surface],
        activeSurfaceID: surface,
        unseenNotificationCount: 0
      )
    ) { TerminalTabFeature() }

    // A same-UUID surface swap bumps only the generation; the leaf must mirror it
    // so the view rebuilds.
    await store.send(
      .projectionChanged(
        WorktreeTabProjection(
          tabID: tabID,
          surfaceIDs: [surface],
          activeSurfaceID: surface,
          unseenNotificationCount: 0,
          surfaceGeneration: 1
        )
      )
    ) {
      $0.surfaceGeneration = 1
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

  @Test func projectionChangedTogglesDormantIndependently() async {
    let tabID = TerminalTabID(rawValue: UUID())
    let surface = UUID()
    let store = TestStore(
      initialState: TerminalTabFeature.State(
        id: tabID,
        worktreeID: "/tmp/repo",
        surfaceIDs: [surface],
        activeSurfaceID: surface,
        unseenNotificationCount: 0
      )
    ) { TerminalTabFeature() }

    // Hibernate: the dormancy flag flows through so the tab bar shows the marker.
    await store.send(
      .projectionChanged(
        WorktreeTabProjection(
          tabID: tabID,
          surfaceIDs: [surface],
          activeSurfaceID: surface,
          unseenNotificationCount: 0,
          isDormant: true
        )
      )
    ) {
      $0.isDormant = true
    }
    // Wake: the flag clears via the same channel.
    await store.send(
      .projectionChanged(
        WorktreeTabProjection(
          tabID: tabID,
          surfaceIDs: [surface],
          activeSurfaceID: surface,
          unseenNotificationCount: 0,
          isDormant: false
        )
      )
    ) {
      $0.isDormant = false
    }
  }

  @Test func agentSnapshotChangedShortCircuitsOnEqualSnapshot() async {
    let tabID = TerminalTabID(rawValue: UUID())
    let snapshot = AgentPresenceFeature.RowSnapshot(
      agents: [AgentPresenceFeature.AgentInstance(agent: .claude, activity: .busy)],
      isWorking: true
    )
    let store = TestStore(
      initialState: TerminalTabFeature.State(
        id: tabID,
        worktreeID: "/tmp/repo",
        agentSnapshot: snapshot
      )
    ) { TerminalTabFeature() }

    await store.send(.agentSnapshotChanged(snapshot))
  }

  @Test func agentSnapshotChangedReplacesSnapshotOnDiff() async {
    let tabID = TerminalTabID(rawValue: UUID())
    let store = TestStore(
      initialState: TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repo")
    ) { TerminalTabFeature() }
    let snapshot = AgentPresenceFeature.RowSnapshot(
      agents: [AgentPresenceFeature.AgentInstance(agent: .codex, activity: .idle)]
    )

    await store.send(.agentSnapshotChanged(snapshot)) {
      $0.agentSnapshot = snapshot
    }
  }

  @Test func shimmerCombinesProgressAgentAndSelectedLifecycleActivity() {
    let tabID = TerminalTabID(rawValue: UUID())
    var state = TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repo")

    #expect(!state.shouldShimmer(isLifecycleRepresentative: false))
    #expect(state.shouldShimmer(isLifecycleRepresentative: true))

    state.hasTerminalActivity = true
    #expect(state.shouldShimmer(isLifecycleRepresentative: false))

    state.hasTerminalActivity = false
    state.agentSnapshot = AgentPresenceFeature.RowSnapshot(isWorking: true)
    #expect(state.agents.isEmpty)
    #expect(state.shouldShimmer(isLifecycleRepresentative: false))

    state.agentSnapshot = AgentPresenceFeature.RowSnapshot(
      agents: [
        AgentPresenceFeature.AgentInstance(agent: .claude, activity: .awaitingInput),
        AgentPresenceFeature.AgentInstance(agent: .codex, activity: .error),
      ]
    )
    #expect(!state.shouldShimmer(isLifecycleRepresentative: false))
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

  @Test func determinateProgressBucketsToCoarseSteps() {
    func percent(_ value: Int) -> Int? {
      guard
        case .determinate(let bucket) = TerminalTabProgressDisplay.make(
          progressState: GHOSTTY_PROGRESS_STATE_SET, progressValue: value
        )?.style
      else { return nil }
      return bucket
    }

    // 0 and the >=100 terminus pass through so the bar starts empty and
    // visibly completes; mid-run values snap to 5% steps and never reach 100.
    #expect(percent(-5) == 0)
    #expect(percent(0) == 0)
    #expect(percent(2) == 0)
    #expect(percent(43) == 45)
    // The min(95) clamp keeps near-full values below the >=100 terminus.
    #expect(percent(97) == 95)
    #expect(percent(98) == 95)
    #expect(percent(100) == 100)
    #expect(percent(101) == 100)
  }
}
