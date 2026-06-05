import ComposableArchitecture
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct SidebarItemFeatureTests {
  // MARK: - Equality-guarded data deltas.

  @Test func diffStatsChangeMutatesOnceThenNoOps() async {
    let store = TestStore(initialState: makeState(name: "feature")) {
      SidebarItemFeature()
    }
    await store.send(.diffStatsChanged(added: 3, removed: 1)) {
      $0.addedLines = 3
      $0.removedLines = 1
    }
    // Same payload: no-op.
    await store.send(.diffStatsChanged(added: 3, removed: 1))
  }

  @Test func lifecycleEqualityGuardSkipsNoOps() async {
    var state = makeState(name: "feature")
    state.lifecycle = .archiving
    let store = TestStore(initialState: state) {
      SidebarItemFeature()
    }
    await store.send(.lifecycleChanged(.archiving))
    await store.send(.lifecycleChanged(.idle)) {
      $0.lifecycle = .idle
    }
  }

  @Test func runningScriptStartedIsIdempotentForSameTint() async {
    let scriptID = UUID()
    let store = TestStore(initialState: makeState(name: "feature")) {
      SidebarItemFeature()
    }
    await store.send(.runningScriptStarted(id: scriptID, tint: .orange)) {
      $0.runningScripts = [.init(id: scriptID, tint: .orange)]
    }
    // Same tint: no-op.
    await store.send(.runningScriptStarted(id: scriptID, tint: .orange))
    await store.send(.runningScriptStarted(id: scriptID, tint: .blue)) {
      $0.runningScripts[id: scriptID]?.tint = .blue
    }
  }

  @Test func runningScriptStopRemovesAndIsIdempotent() async {
    let scriptID = UUID()
    let store = TestStore(initialState: makeState(name: "feature")) {
      SidebarItemFeature()
    }
    await store.send(.runningScriptStarted(id: scriptID, tint: .orange)) {
      $0.runningScripts = [.init(id: scriptID, tint: .orange)]
    }
    await store.send(.runningScriptStopped(id: scriptID)) {
      $0.runningScripts = []
    }
    // Stopping an unknown id is a no-op.
    await store.send(.runningScriptStopped(id: UUID()))
  }

  @Test func agentSnapshotEqualityGuardSkipsNoOps() async {
    let store = TestStore(initialState: makeState(name: "feature")) {
      SidebarItemFeature()
    }
    let instance = AgentPresenceFeature.AgentInstance(
      agent: .claude,
      activity: .busy
    )
    await store.send(.agentSnapshotChanged([instance], hasActivity: true)) {
      $0.agents = [instance]
      $0.hasAgentActivity = true
    }
    // Same payload: no-op.
    await store.send(.agentSnapshotChanged([instance], hasActivity: true))
    // hasActivity flip only.
    await store.send(.agentSnapshotChanged([instance], hasActivity: false)) {
      $0.hasAgentActivity = false
    }
  }

  // MARK: - Terminal projection per-field guards.

  @Test func terminalProjectionEachFieldGuardedIndependently() async {
    let store = TestStore(initialState: makeState(name: "feature")) {
      SidebarItemFeature()
    }
    let surface1 = UUID()
    let surface2 = UUID()
    let notif = WorktreeTerminalNotification(
      surfaceID: surface1,
      title: "Notification",
      body: "hi",
      createdAt: Date(timeIntervalSince1970: 0)
    )
    let baseline = WorktreeRowProjection(
      surfaceIDs: [surface1],
      isProgressBusy: false,
      hasUnseenNotifications: false,
      notifications: []
    )
    await store.send(.terminalProjectionChanged(baseline)) {
      $0.hasTerminalProjection = true
      $0.surfaceIDs = [surface1]
    }
    // Identical projection: no mutation.
    await store.send(.terminalProjectionChanged(baseline))
    // surfaceIDs alone changes.
    await store.send(
      .terminalProjectionChanged(
        WorktreeRowProjection(
          surfaceIDs: [surface1, surface2],
          isProgressBusy: false,
          hasUnseenNotifications: false,
          notifications: []
        )
      )
    ) {
      $0.surfaceIDs = [surface1, surface2]
    }
    // isProgressBusy alone changes (and `isTaskRunning` derives from it).
    await store.send(
      .terminalProjectionChanged(
        WorktreeRowProjection(
          surfaceIDs: [surface1, surface2],
          isProgressBusy: true,
          hasUnseenNotifications: false,
          notifications: []
        )
      )
    ) {
      $0.isProgressBusy = true
    }
    // hasUnseenNotifications flips alone (independent of `notifications`).
    await store.send(
      .terminalProjectionChanged(
        WorktreeRowProjection(
          surfaceIDs: [surface1, surface2],
          isProgressBusy: true,
          hasUnseenNotifications: true,
          notifications: []
        )
      )
    ) {
      $0.hasUnseenNotifications = true
    }
    // notifications flip alone.
    await store.send(
      .terminalProjectionChanged(
        WorktreeRowProjection(
          surfaceIDs: [surface1, surface2],
          isProgressBusy: true,
          hasUnseenNotifications: true,
          notifications: [notif]
        )
      )
    ) {
      $0.notifications = [notif]
    }
  }

  // MARK: - Stale-PR guard.

  @Test func pullRequestChangedDropsResultWhenBranchHasFlipped() async {
    // Post-flip state: row's branch is already "feature/y", a live PR is in place,
    // and a late result from the prior "feature/x" query is about to arrive.
    var state = makeState(name: "feature/y")
    state.branchName = "feature/y"
    let livePR = GithubPullRequest(
      number: 12,
      title: "Live",
      state: "OPEN",
      additions: 1,
      deletions: 0,
      isDraft: false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      url: "https://example.com/pull/12",
      headRefName: "feature/y",
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "tester",
      statusCheckRollup: nil,
      mergeQueueEntry: nil
    )
    state.pullRequest = livePR
    let store = TestStore(initialState: state) {
      SidebarItemFeature()
    }
    let stalePR = GithubPullRequest(
      number: 99,
      title: "Stale",
      state: "OPEN",
      additions: 0,
      deletions: 0,
      isDraft: false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      url: "https://example.com/pull/99",
      headRefName: "feature/x",
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "tester",
      statusCheckRollup: nil,
      mergeQueueEntry: nil
    )
    // Late stale result must not replace the live PR.
    await store.send(.pullRequestChanged(stalePR, branchAtQueryTime: "feature/x"))
    #expect(store.state.pullRequest == livePR)
  }

  @Test func pullRequestChangedClearsWatermarkOnSuccessAndOnIdenticalReissue() async {
    var state = makeState(name: "feature")
    state.branchName = "feature"
    let store = TestStore(initialState: state) {
      SidebarItemFeature()
    }
    let pullRequest = GithubPullRequest(
      number: 1,
      title: "First",
      state: "OPEN",
      additions: 1,
      deletions: 0,
      isDraft: false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      url: "https://example.com/pull/1",
      headRefName: "feature",
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "tester",
      statusCheckRollup: nil,
      mergeQueueEntry: nil
    )
    await store.send(.pullRequestQueryStarted(branch: "feature")) {
      $0.pullRequestBranchAtQueryTime = "feature"
    }
    // Success path: PR is written and watermark cleared.
    await store.send(.pullRequestChanged(pullRequest, branchAtQueryTime: "feature")) {
      $0.pullRequest = pullRequest
      $0.pullRequestBranchAtQueryTime = nil
    }
    // Identical-payload reissue with a re-armed watermark: PR unchanged, watermark still cleared.
    await store.send(.pullRequestQueryStarted(branch: "feature")) {
      $0.pullRequestBranchAtQueryTime = "feature"
    }
    await store.send(.pullRequestChanged(pullRequest, branchAtQueryTime: "feature")) {
      $0.pullRequestBranchAtQueryTime = nil
    }
  }

  @Test func pullRequestQueryStartedEqualityGuardSkipsNoOps() async {
    var state = makeState(name: "feature")
    state.pullRequestBranchAtQueryTime = "feature"
    let store = TestStore(initialState: state) {
      SidebarItemFeature()
    }
    // Same branch: no-op.
    await store.send(.pullRequestQueryStarted(branch: "feature"))
    await store.send(.pullRequestQueryStarted(branch: "other")) {
      $0.pullRequestBranchAtQueryTime = "other"
    }
  }

  // MARK: - UI-scalar guards.

  @Test func dragSessionGuardSkipsNoOps() async {
    let store = TestStore(initialState: makeState(name: "feature")) {
      SidebarItemFeature()
    }
    await store.send(.dragSessionChanged(isDragging: true)) {
      $0.isDragging = true
    }
    // Same drag state: no-op.
    await store.send(.dragSessionChanged(isDragging: true))
  }

  // MARK: - Helpers.

  private func makeState(name: String) -> SidebarItemFeature.State {
    SidebarItemFeature.State(
      id: "/tmp/repo/wt-\(name)",
      repositoryID: "/tmp/repo",
      kind: .gitWorktree,
      name: name,
      branchName: name,
      subtitle: nil,
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-\(name)"),
      repositoryAccent: nil,
      isMainWorktree: false,
      isPinned: false,
      hasMergedBadge: false
    )
  }
}
