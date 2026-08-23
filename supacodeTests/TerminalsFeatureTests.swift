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
    /// Drives injected memory-pressure warnings; `.task` must be sent to subscribe.
    let pressure: AsyncStream<Void>.Continuation
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
    let pressure = AsyncStream<Void>.makeStream()
    let store = TestStore(
      initialState: TerminalsFeature.State(layouts: [LayoutFeature.State(id: worktreeID, layout: layout)])
    ) {
      TerminalsFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.contentRuntime = runtime
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
      $0[MemoryPressureClient.self] = MemoryPressureClient(warnings: { pressure.stream })
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
      hiddenContent: hiddenContent,
      pressure: pressure.continuation
    )
  }

  @Test(.dependencies) func hiddenTabHibernatesAfterTheGraceWindow() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
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
      $0.recentWorktreeIDs = [harness.worktreeID]
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
      $0.recentWorktreeIDs = [harness.worktreeID]
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
      $0.recentWorktreeIDs = [harness.worktreeID]
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
      $0.recentWorktreeIDs = [harness.worktreeID]
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

  @Test(.dependencies) func windowedPaneKeepsItsSelectionAwakeWhileTheWorktreeIsUnselected() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .enterWindowMode(paneID: harness.paneID)))
    ) {
      $0.layouts[id: harness.worktreeID]?.windowedPaneIDs = [harness.paneID]
      // The pane's unselected tab still hides behind its strip and arms.
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    // The window floats over any worktree; leaving this one must not arm its
    // selection.
    await harness.store.send(.selectedWorktreeChanged(Worktree.ID("/tmp/other"))) {
      $0.selectedWorktreeID = Worktree.ID("/tmp/other")
      $0.recentWorktreeIDs = [Worktree.ID("/tmp/other")]
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    #expect(harness.selectedContent.renderer != nil)
    #expect(harness.hiddenContent.renderer == nil)
  }

  @Test(.dependencies) func leavingWindowModeArmsTheSelectionOfAnUnselectedWorktree() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .enterWindowMode(paneID: harness.paneID)))
    ) {
      $0.layouts[id: harness.worktreeID]?.windowedPaneIDs = [harness.paneID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    await harness.store.send(.selectedWorktreeChanged(Worktree.ID("/tmp/other"))) {
      $0.selectedWorktreeID = Worktree.ID("/tmp/other")
      $0.recentWorktreeIDs = [Worktree.ID("/tmp/other")]
    }
    // Re-attaching withdraws the exemption: the selection is hidden again.
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .exitWindowMode(paneID: harness.paneID)))
    ) {
      $0.layouts[id: harness.worktreeID]?.windowedPaneIDs = []
      $0.hibernationArmedTabs = [harness.selectedTab, harness.hiddenTab]
    }
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.finish()
  }

  @Test(.dependencies) func windowedPaneWakesItsHibernatedSelectionWhileTheWorktreeIsUnselected() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    harness.selectedContent.hibernate()
    // Windowing a pane whose selection is hibernated must re-provision it,
    // or the window opens dead.
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .enterWindowMode(paneID: harness.paneID)))
    ) {
      $0.layouts[id: harness.worktreeID]?.windowedPaneIDs = [harness.paneID]
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

  @Test(.dependencies) func zoomedPaneHidesTheOtherPanesSelectedTab() async throws {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let worktreeID = Worktree.ID("/tmp/zoom")
    let paneA = PaneID()
    let paneB = PaneID()
    let tabA = TabID()
    let tabB = TabID()
    let contentA = HibernatableContent(id: ContentID())
    let contentB = HibernatableContent(id: ContentID())
    let runtime = ContentRuntime()
    _ = runtime.provision(contentA, at: .fallback)
    _ = runtime.provision(contentB, at: .fallback)
    var tree = try SplitTree(view: paneA).inserting(view: paneB, at: paneA, direction: .right)
    tree = tree.settingZoomed(try #require(tree.find(id: paneA.rawValue)))
    let layout = PaneLayout(
      tree: tree,
      panes: [
        Pane(
          id: paneA,
          tabs: [
            TabItem(
              id: tabA,
              title: "A",
              content: ContentSnapshot(
                id: contentA.id,
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: tabA
        ),
        Pane(
          id: paneB,
          tabs: [
            TabItem(
              id: tabB,
              title: "B",
              content: ContentSnapshot(
                id: contentB.id,
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: tabB
        ),
      ],
      focusedPaneID: paneA
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
    await store.send(.selectedWorktreeChanged(worktreeID)) {
      $0.selectedWorktreeID = worktreeID
      $0.recentWorktreeIDs = [worktreeID]
      // Pane B sits behind the zoom, so its selection is hidden and arms.
      $0.hibernationArmedTabs = [tabB]
    }
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
  }

  @Test(.dependencies) func detachLayoutCancelsArmedGraceTimers() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    // Selecting another worktree hides both tabs; both arm.
    await harness.store.send(.selectedWorktreeChanged(Worktree.ID("/tmp/other"))) {
      $0.selectedWorktreeID = Worktree.ID("/tmp/other")
      $0.recentWorktreeIDs = [Worktree.ID("/tmp/other")]
      $0.hibernationArmedTabs = [harness.selectedTab, harness.hiddenTab]
    }
    await harness.store.send(.detachLayout(worktreeID: harness.worktreeID)) {
      $0.layouts = []
      $0.hibernationArmedTabs = []
    }
    // Cancelled timers must never fire.
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.finish()
  }

  @Test(.dependencies) func aRecentWorktreesSelectionStaysLiveWhileDeselected() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    // Deselecting keeps the worktree inside the recency window, so its visible
    // selection is retained (never arms) even though it is now hidden; only the
    // stacked tab stays armed.
    await harness.store.send(.selectedWorktreeChanged(Worktree.ID("/tmp/other"))) {
      $0.selectedWorktreeID = Worktree.ID("/tmp/other")
      $0.recentWorktreeIDs = [Worktree.ID("/tmp/other"), harness.worktreeID]
    }
    // Advance well past the grace window: a retained selection never arms, so no
    // amount of idle time hibernates it, while the stacked tab fires once.
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow * 2)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    // The stacked tab hibernated; the recency-retained selection did not.
    #expect(harness.hiddenContent.renderer == nil)
    #expect(harness.selectedContent.renderer != nil)
    await harness.store.finish()
  }

  @Test(.dependencies) func aWorktreePushedOutOfTheRecencyWindowArmsItsSelection() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    // Visit enough other worktrees to push this one past `liveWorktreeLimit`.
    let others = ["/tmp/o1", "/tmp/o2", "/tmp/o3"].map { Worktree.ID($0) }
    await harness.store.send(.selectedWorktreeChanged(others[0])) {
      $0.selectedWorktreeID = others[0]
      $0.recentWorktreeIDs = [others[0], harness.worktreeID]
    }
    await harness.store.send(.selectedWorktreeChanged(others[1])) {
      $0.selectedWorktreeID = others[1]
      $0.recentWorktreeIDs = [others[1], others[0], harness.worktreeID]
    }
    await harness.store.send(.selectedWorktreeChanged(others[2])) {
      $0.selectedWorktreeID = others[2]
      // The worktree drops out of the window, so its selection loses recency
      // cover and arms alongside the stacked tab.
      $0.recentWorktreeIDs = [others[2], others[1], others[0]]
      $0.hibernationArmedTabs = [harness.hiddenTab, harness.selectedTab]
    }
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.finish()
  }

  @Test(.dependencies) func memoryPressureDropsRecencyAndHibernatesEveryHiddenTab() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    // The sweep fans out one hibernate per hidden tab; assert the outcome, not
    // each cascading action.
    harness.store.exhaustivity = .off
    await harness.store.send(.task)
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID))
    // Deselect but stay recent: without pressure the selection is retained live.
    await harness.store.send(.selectedWorktreeChanged(Worktree.ID("/tmp/other")))
    #expect(harness.selectedContent.renderer != nil)

    harness.pressure.yield()
    await harness.store.receive(\.memoryPressureWarning)
    await harness.store.skipReceivedActions()

    // Recency collapses to the current selection, and the deselected worktree's
    // retained selection hibernates now instead of waiting out the grace window.
    #expect(harness.store.state.recentWorktreeIDs == [Worktree.ID("/tmp/other")])
    #expect(harness.selectedContent.renderer == nil)
    #expect(harness.hiddenContent.renderer == nil)

    harness.pressure.finish()
    await harness.store.finish()
  }

  @Test(.dependencies) func memoryPressureSparesTheVisibleSelection() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    harness.store.exhaustivity = .off
    await harness.store.send(.task)
    // The worktree stays selected across the pressure event.
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID))

    harness.pressure.yield()
    await harness.store.receive(\.memoryPressureWarning)
    await harness.store.skipReceivedActions()

    // The on-screen selection survives; only the stacked tab hibernates.
    #expect(harness.selectedContent.renderer != nil)
    #expect(harness.hiddenContent.renderer == nil)

    harness.pressure.finish()
    await harness.store.finish()
  }

  @Test(.dependencies) func pressureSparesATabReselectedBeforeItsHibernateLands() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    harness.store.exhaustivity = .off
    await harness.store.send(.task)
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID))
    // Deselect so the selection tab is hidden and becomes a pressure target.
    await harness.store.send(.selectedWorktreeChanged(Worktree.ID("/tmp/other")))

    harness.pressure.yield()
    await harness.store.receive(\.memoryPressureWarning)
    // Before the queued hibernations land, the user flips back, making the
    // selection visible again. Routing pressure through the fire-time action
    // means its re-check spares the now-visible tab.
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID))
    await harness.store.skipReceivedActions()

    #expect(harness.selectedContent.renderer != nil)

    // The reselect re-armed the stacked tab's grace timer; drain it so the
    // store finishes with no in-flight effect.
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.skipReceivedActions()
    harness.pressure.finish()
    await harness.store.finish()
  }

  @Test(.dependencies) func memoryPressureRespectsTheHibernationFlag() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    let harness = makeHibernationHarness()
    await harness.store.send(.task)
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
    }
    await harness.store.send(.selectedWorktreeChanged(Worktree.ID("/tmp/other"))) {
      $0.selectedWorktreeID = Worktree.ID("/tmp/other")
      $0.recentWorktreeIDs = [Worktree.ID("/tmp/other"), harness.worktreeID]
    }

    harness.pressure.yield()
    // Hibernation disabled: the warning is a no-op. No surface is dropped and
    // the recency budget is left intact.
    await harness.store.receive(\.memoryPressureWarning)
    #expect(harness.selectedContent.renderer != nil)
    #expect(harness.hiddenContent.renderer != nil)
    #expect(harness.store.state.recentWorktreeIDs == [Worktree.ID("/tmp/other"), harness.worktreeID])

    harness.pressure.finish()
    await harness.store.finish()
  }

  @Test(.dependencies) func theFireTimeGateSparesASelectionThatBecameRecent() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    // Deselect but stay recent: the selection is retained, never armed.
    await harness.store.send(.selectedWorktreeChanged(Worktree.ID("/tmp/other"))) {
      $0.selectedWorktreeID = Worktree.ID("/tmp/other")
      $0.recentWorktreeIDs = [Worktree.ID("/tmp/other"), harness.worktreeID]
    }
    // A grace timer that fired for the now-retained selection (a race the
    // arm-time cancel could miss) must not hibernate it: the fire-time gate wins.
    await harness.store.send(
      .hibernationGraceElapsed(worktreeID: harness.worktreeID, tabID: harness.selectedTab)
    )
    #expect(harness.selectedContent.renderer != nil)
    // Drain the stacked tab's still-armed timer.
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.finish()
  }

  @Test(.dependencies) func graceElapsedSettlesInsteadOfReArmingAHibernatedTab() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    // The armed tab hibernates out of band (as a concurrent pressure sweep
    // would), so when its grace timer fires there is nothing left to hibernate.
    harness.hiddenContent.hibernate()
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
    }
    // Settled, not re-armed: a second window produces no further grace action.
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.finish()
  }

  @Test(.dependencies) func reSelectingARecentWorktreeMovesItToFrontWithoutGrowing() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    let harness = makeHibernationHarness()
    let worktreeA = harness.worktreeID
    let worktreeB = Worktree.ID("/tmp/b")
    await harness.store.send(.selectedWorktreeChanged(worktreeA)) {
      $0.selectedWorktreeID = worktreeA
      $0.recentWorktreeIDs = [worktreeA]
    }
    await harness.store.send(.selectedWorktreeChanged(worktreeB)) {
      $0.selectedWorktreeID = worktreeB
      $0.recentWorktreeIDs = [worktreeB, worktreeA]
    }
    // Re-selecting the first worktree moves it to front without duplicating or growing the list.
    await harness.store.send(.selectedWorktreeChanged(worktreeA)) {
      $0.selectedWorktreeID = worktreeA
      $0.recentWorktreeIDs = [worktreeA, worktreeB]
    }
  }

  @Test(.dependencies) func detachLayoutRemovesTheWorktreeFromRecents() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
    }
    await harness.store.send(.detachLayout(worktreeID: harness.worktreeID)) {
      $0.layouts = []
      $0.recentWorktreeIDs = []
    }
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

  @Test func layoutsHydrationDropsCrossWorktreeIDCollisions() async {
    let sharedContentID = ContentID()
    let first = Self.layout(paneID: PaneID(), tabID: TabID(), contentID: sharedContentID)
    // The second worktree reuses the same content id (pre-gate data); it would
    // collide in the globally keyed runtime, so only the first key hydrates.
    let second = Self.layout(paneID: PaneID(), tabID: TabID(), contentID: sharedContentID)
    let file = LayoutsFile(worktrees: [
      "/tmp/a": LayoutRecord(layout: first),
      "/tmp/b": LayoutRecord(layout: second),
    ])
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    await store.send(.layoutsHydrated(file)) {
      $0.layouts = [LayoutFeature.State(id: Worktree.ID("/tmp/a"), layout: first)]
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
}
