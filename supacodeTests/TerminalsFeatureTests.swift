import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct TerminalsFeatureTests {
  /// Minimal live content whose renderer and eligibility the tests control.
  @MainActor
  private final class HibernatableContent: TabContent {
    let id: ContentID
    let kind: ContentKind = .terminal
    /// Eligibility knob for the fire-time re-arm path.
    var claimsHibernation = true
    private(set) var startCalls = 0
    private var view: NSView?
    private let state: TerminalContentState

    init(id: ContentID, state: TerminalContentState = TerminalContentState(workingDirectory: nil)) {
      self.id = id
      self.state = state
    }

    var renderer: NSView? { view }
    var isHibernatable: Bool { view != nil && claimsHibernation }

    func startSession(at geometry: ContentGeometry) {
      startCalls += 1
      guard view == nil else { return }
      view = NSView()
    }

    func hibernate() {
      view = nil
    }

    func snapshot() -> ContentSnapshot {
      ContentSnapshot(id: id, state: .terminal(state))
    }
  }
  private static func layout(paneID: PaneID, tabID: TabID, contentID: ContentID) -> PaneLayout {
    PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: tabID,
              title: "One",
              content: ContentSnapshot(
                id: contentID,
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: tabID
        )
      ],
      focusedPaneID: paneID
    )
  }

  // MARK: - Hibernation.

  private struct HibernationHarness {
    let store: TestStoreOf<TerminalsFeature>
    let clock: TestClock<Duration>
    let runtime: ContentRuntime
    let worktreeID: Worktree.ID
    let paneID: PaneID
    let selectedTab: TabID
    let hiddenTab: TabID
    let selectedContent: HibernatableContent
    let hiddenContent: HibernatableContent
  }

  /// One worktree, one pane, two tabs; both contents live in the runtime.
  private func makeHibernationHarness(startSessions: Bool = true) -> HibernationHarness {
    let worktreeID = Worktree.ID("/tmp/hib")
    let paneID = PaneID()
    let selectedTab = TabID()
    let hiddenTab = TabID()
    let selectedContent = HibernatableContent(id: ContentID())
    let hiddenContent = HibernatableContent(id: ContentID())
    let runtime = ContentRuntime()
    if startSessions {
      _ = runtime.provision(selectedContent, at: .fallback)
      _ = runtime.provision(hiddenContent, at: .fallback)
    }
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: selectedTab,
              title: "One",
              content: ContentSnapshot(
                id: selectedContent.id,
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            ),
            TabItem(
              id: hiddenTab,
              title: "Two",
              content: ContentSnapshot(
                id: hiddenContent.id,
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            ),
          ],
          selectedTabID: selectedTab
        )
      ],
      focusedPaneID: paneID
    )
    let clock = TestClock()
    let store = TestStore(
      initialState: TerminalsFeature.State(layouts: [LayoutFeature.State(id: worktreeID, layout: layout)])
    ) {
      TerminalsFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.contentRuntime = runtime
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    return HibernationHarness(
      store: store,
      clock: clock,
      runtime: runtime,
      worktreeID: worktreeID,
      paneID: paneID,
      selectedTab: selectedTab,
      hiddenTab: hiddenTab,
      selectedContent: selectedContent,
      hiddenContent: hiddenContent
    )
  }

  @Test(.dependencies) func hiddenTabHibernatesAfterTheGraceWindow() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    #expect(harness.hiddenContent.renderer == nil)
    #expect(harness.selectedContent.renderer != nil)
  }

  @Test(.dependencies) func selectingTheTabCancelsItsGraceTimer() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    // Selecting the hidden tab makes it visible and hides the other one.
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .selectTab(id: harness.hiddenTab)))
    ) {
      $0.layouts[id: harness.worktreeID]?.layout.panes[id: harness.paneID]?.selectedTabID = harness.hiddenTab
      $0.hibernationArmedTabs = [harness.selectedTab]
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    // Only the newly hidden tab fires; the cancelled timer stays silent.
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    #expect(harness.hiddenContent.renderer != nil)
    #expect(harness.selectedContent.renderer == nil)
  }

  @Test(.dependencies) func disablingTheFlagCancelsPendingTimers() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    #expect(harness.hiddenContent.renderer != nil)
  }

  @Test(.dependencies) func ineligibleHiddenTabReArmsAtFireTime() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    harness.hiddenContent.claimsHibernation = false
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationDeferralLogged = [harness.hiddenTab]
    }
    #expect(harness.hiddenContent.renderer != nil)
    // Eligibility returns; the re-armed timer hibernates on the next window.
    harness.hiddenContent.claimsHibernation = true
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
      $0.hibernationDeferralLogged = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    #expect(harness.hiddenContent.renderer == nil)
  }

  @Test(.dependencies) func selectingAWorktreeWakesItsHibernatedSelection() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    harness.selectedContent.hibernate()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.hibernationArmedTabs = [harness.hiddenTab]
      $0.wakeRequestedTabs = [harness.selectedTab]
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
      $0.wakeRequestedTabs = []
    }
    #expect(harness.selectedContent.renderer != nil)
    // Drain the armed timer so the store finishes clean.
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.finish()
  }

  @Test func layoutsHydrationServesConsistentRecordsOnly() async {
    let paneID = PaneID()
    let good = Self.layout(paneID: paneID, tabID: TabID(), contentID: ContentID())
    // A tree leaf with no matching pane fails the consistency gate.
    let bad = PaneLayout(tree: SplitTree(view: PaneID()), panes: [], focusedPaneID: nil)
    let file = LayoutsFile(worktrees: [
      "/tmp/good": LayoutRecord(layout: good),
      "/tmp/bad": LayoutRecord(layout: bad),
    ])
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    await store.send(.layoutsHydrated(file)) {
      $0.layouts = [LayoutFeature.State(id: Worktree.ID("/tmp/good"), layout: good)]
    }
  }

  @Test func layoutsHydrationNeverReplacesALiveLayout() async {
    let live = Self.layout(paneID: PaneID(), tabID: TabID(), contentID: ContentID())
    let persisted = Self.layout(paneID: PaneID(), tabID: TabID(), contentID: ContentID())
    let worktreeID = Worktree.ID("/tmp/repo")
    let store = TestStore(
      initialState: TerminalsFeature.State(layouts: [LayoutFeature.State(id: worktreeID, layout: live)])
    ) {
      TerminalsFeature()
    }
    await store.send(.layoutsHydrated(LayoutsFile(worktrees: ["/tmp/repo": LayoutRecord(layout: persisted)])))
  }

  @Test func newerSchemaServesRecordsButMarksThemReadOnly() async {
    let good = Self.layout(paneID: PaneID(), tabID: TabID(), contentID: ContentID())
    let file = LayoutsFile(
      schemaVersion: LayoutsFile.currentSchemaVersion + 1,
      worktrees: ["/tmp/good": LayoutRecord(layout: good)]
    )
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    await store.send(.layoutsHydrated(file)) {
      $0.layoutsAreReadOnly = true
      $0.layouts = [LayoutFeature.State(id: Worktree.ID("/tmp/good"), layout: good)]
    }
  }
  @Test func tabProjectionChangedInsertsNewTabThenForwards() async {
    let tabID = TabID(rawValue: UUID())
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
    let tabID = TabID(rawValue: UUID())
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
    let tabID = TabID(rawValue: UUID())
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
    var allIDs: [TabID] = []
    for _ in 0..<(limit + 5) {
      let id = TabID(rawValue: UUID())
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
    let tabA1 = TabID(rawValue: UUID())
    let tabA2 = TabID(rawValue: UUID())
    let tabB1 = TabID(rawValue: UUID())
    var initial = TerminalsFeature.State()
    initial.terminalTabs.append(TerminalTabFeature.State(id: tabA1, worktreeID: "/tmp/repoA"))
    initial.terminalTabs.append(TerminalTabFeature.State(id: tabA2, worktreeID: "/tmp/repoA"))
    initial.terminalTabs.append(TerminalTabFeature.State(id: tabB1, worktreeID: "/tmp/repoB"))
    initial.recentlyRemovedTabIDs = [
      TerminalsFeature.RecentlyRemovedTab(
        worktreeID: "/tmp/repoA", tabID: TabID(rawValue: UUID())),
      TerminalsFeature.RecentlyRemovedTab(
        worktreeID: "/tmp/repoB", tabID: TabID(rawValue: UUID())),
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
    let tabID = TabID(rawValue: UUID())
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
