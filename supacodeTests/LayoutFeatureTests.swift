import AppKit
import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct LayoutFeatureTests {
  // MARK: - Mocks.

  @MainActor
  private final class MockTabContent: TabContent {
    let id: ContentID
    let kind: ContentKind = .terminal
    /// Marker returned by `snapshot()` in place of the creation state.
    var snapshotState: TerminalContentState?
    private let initialState: TerminalContentState
    private(set) var startGeometries: [ContentGeometry] = []
    /// Every invocation, including no-op re-starts the guard swallows.
    private(set) var startCalls = 0
    private(set) var hibernateCalls = 0
    private var view: NSView?

    init(id: ContentID, initialState: TerminalContentState) {
      self.id = id
      self.initialState = initialState
    }

    var renderer: NSView? { view }

    func startSession(at geometry: ContentGeometry) {
      startCalls += 1
      // Mirror the protocol contract: a second call while live is a no-op.
      guard view == nil else { return }
      startGeometries.append(geometry)
      view = NSView()
    }

    func hibernate() {
      hibernateCalls += 1
      view = nil
    }

    func snapshot() -> ContentSnapshot {
      ContentSnapshot(id: id, state: .terminal(snapshotState ?? initialState))
    }
  }

  /// Factory stand-in recording every created content and its seed state.
  @MainActor
  private final class ContentRecorder {
    private(set) var contents: [ContentID: MockTabContent] = [:]
    private(set) var madeStates: [TerminalContentState] = []
    private(set) var madeWorktreeIDs: [Worktree.ID] = []

    func make(
      _ worktreeID: Worktree.ID,
      _ contentID: ContentID,
      _ initialState: TerminalContentState
    ) -> any TabContent {
      let content = MockTabContent(id: contentID, initialState: initialState)
      contents[contentID] = content
      madeStates.append(initialState)
      madeWorktreeIDs.append(worktreeID)
      return content
    }
  }

  private struct Harness {
    let store: TestStoreOf<LayoutFeature>
    let runtime: ContentRuntime
    let recorder: ContentRecorder
    let paneID: PaneID
    let tabID: TerminalTabID
    let contentID: ContentID

    var mock: MockTabContent? { recorder.contents[contentID] }
  }

  // MARK: - Helpers.

  private static let seedState = TerminalContentState(workingDirectory: "/tmp/layout-feature")

  private static func spec(
    tabID: TerminalTabID? = nil,
    contentID: ContentID? = nil,
    title: String = "Tab",
    geometry: ContentGeometry = .fallback,
    select: Bool = true
  ) -> NewTabSpec {
    NewTabSpec(
      tabID: tabID,
      contentID: contentID,
      title: title,
      initialState: seedState,
      geometry: geometry,
      select: select
    )
  }

  private static func tab(
    id tabID: TerminalTabID,
    contentID: ContentID,
    title: String,
    state: TerminalContentState = seedState
  ) -> TabItem {
    TabItem(id: tabID, title: title, content: ContentSnapshot(id: contentID, state: .terminal(state)))
  }

  private struct StoreBundle {
    let store: TestStoreOf<LayoutFeature>
    let runtime: ContentRuntime
    let recorder: ContentRecorder
  }

  private func makeStore(
    layout: PaneLayout,
    preserveZoom: Bool = false,
    killer: ContentSessionKiller? = nil
  ) -> StoreBundle {
    let runtime = ContentRuntime()
    let recorder = ContentRecorder()
    let store = TestStore(
      initialState: LayoutFeature.State(id: WorktreeID("/tmp/layout-feature"), layout: layout)
    ) {
      LayoutFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.contentRuntime = runtime
      $0[SplitZoomPolicy.self] = SplitZoomPolicy(preservesZoomOnNavigation: { preserveZoom })
      $0.layoutContentFactory = LayoutContentFactory(
        make: { worktreeID, contentID, initialState in recorder.make(worktreeID, contentID, initialState) }
      )
      // The registered testValue is loud on purpose; the harness always
      // installs a real (if inert) killer so close paths stay exercisable.
      $0[ContentSessionKiller.self] = killer ?? ContentSessionKiller(kill: { _, _ in })
    }
    return StoreBundle(store: store, runtime: runtime, recorder: recorder)
  }

  /// Builds a store whose layout holds one pane with one tab, created through
  /// `newTab` so the runtime and factory both saw the bootstrap.
  private func makeHarness(
    paneID: PaneID = PaneID(),
    preserveZoom: Bool = false,
    killer: ContentSessionKiller? = nil
  ) async -> Harness {
    let tabID = TerminalTabID()
    let contentID = ContentID()
    let bundle = makeStore(
      layout: PaneLayout(
        tree: SplitTree(view: paneID),
        panes: [Pane(id: paneID)],
        focusedPaneID: paneID
      ),
      preserveZoom: preserveZoom,
      killer: killer
    )
    await bundle.store.send(
      .newTab(inPane: paneID, spec: Self.spec(tabID: tabID, contentID: contentID, title: "One"))
    ) {
      $0.layout.panes[id: paneID]?.tabs = [Self.tab(id: tabID, contentID: contentID, title: "One")]
      $0.layout.panes[id: paneID]?.selectedTabID = tabID
    }
    return Harness(
      store: bundle.store,
      runtime: bundle.runtime,
      recorder: bundle.recorder,
      paneID: paneID,
      tabID: tabID,
      contentID: contentID
    )
  }

  /// Appends a selected tab to the harness pane, mirroring insert-after-selection.
  @discardableResult
  private func addTab(
    _ harness: Harness,
    title: String
  ) async -> (tabID: TerminalTabID, contentID: ContentID) {
    let tabID = TerminalTabID()
    let contentID = ContentID()
    let paneID = harness.paneID
    await harness.store.send(
      .newTab(inPane: paneID, spec: Self.spec(tabID: tabID, contentID: contentID, title: title))
    ) {
      // The selection sits at the tail in every caller, so insert-after-selection appends.
      $0.layout.panes[id: paneID]?.tabs.append(Self.tab(id: tabID, contentID: contentID, title: title))
      $0.layout.panes[id: paneID]?.selectedTabID = tabID
    }
    return (tabID, contentID)
  }

  private struct SplitResult {
    let paneID: PaneID
    let tabID: TerminalTabID
    let contentID: ContentID
  }

  /// Splits from `anchor`, minting the new pane id from the incrementing UUID.
  private func splitPane(
    _ harness: Harness,
    anchor: PaneID,
    direction: SplitTree<PaneID>.NewDirection = .right,
    mintIndex: Int = 0,
    title: String = "Split"
  ) async -> SplitResult {
    let newPaneID = PaneID(rawValue: UUID(mintIndex))
    let tabID = TerminalTabID()
    let contentID = ContentID()
    await harness.store.send(
      .splitPane(id: anchor, direction: direction, spec: Self.spec(tabID: tabID, contentID: contentID, title: title))
    ) {
      $0.layout.tree = try $0.layout.tree.inserting(view: newPaneID, at: anchor, direction: direction)
      $0.layout.panes.append(
        Pane(id: newPaneID, tabs: [Self.tab(id: tabID, contentID: contentID, title: title)], selectedTabID: tabID)
      )
      $0.layout.focusedPaneID = newPaneID
    }
    return SplitResult(paneID: newPaneID, tabID: tabID, contentID: contentID)
  }

  // MARK: - New tab.

  @Test func newTabProvisionsAndStartsSessionOnceAtGivenGeometry() async throws {
    let harness = await makeHarness()
    let geometry = try #require(ContentGeometry.candidate(pointSize: CGSize(width: 900, height: 600), scale: 2))
    let tabID = TerminalTabID()
    let contentID = ContentID()
    await harness.store.send(
      .newTab(inPane: harness.paneID, spec: Self.spec(tabID: tabID, contentID: contentID, geometry: geometry))
    ) {
      $0.layout.panes[id: harness.paneID]?.tabs.insert(Self.tab(id: tabID, contentID: contentID, title: "Tab"), at: 1)
      $0.layout.panes[id: harness.paneID]?.selectedTabID = tabID
    }
    let mock = try #require(harness.recorder.contents[contentID])
    #expect(mock.startGeometries == [geometry])
    #expect(mock.startCalls == 1)
    #expect(harness.runtime.content(for: contentID) === mock)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func newTabProvisionRefusalLeavesStateUntouched() async {
    let harness = await makeHarness()
    let contentID = ContentID()
    // Tombstone the identity up front so the runtime refuses to provision it.
    harness.runtime.remove(contentID, tombstone: true)
    await harness.store.send(
      .newTab(inPane: harness.paneID, spec: Self.spec(tabID: TerminalTabID(), contentID: contentID))
    )
    #expect(harness.recorder.contents[contentID]?.startGeometries.isEmpty == true)
    #expect(harness.runtime.content(for: contentID) == nil)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func newTabBackgroundAppendsWithoutTakingSelectionOrFocus() async {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    let tabID = TerminalTabID()
    let contentID = ContentID()
    await harness.store.send(
      .newTab(
        inPane: harness.paneID,
        spec: Self.spec(tabID: tabID, contentID: contentID, title: "Back", select: false)
      )
    ) {
      $0.layout.panes[id: harness.paneID]?.tabs.append(Self.tab(id: tabID, contentID: contentID, title: "Back"))
    }
    #expect(harness.store.state.layout.panes[id: harness.paneID]?.selectedTabID == harness.tabID)
    #expect(harness.store.state.layout.focusedPaneID == split.paneID)
    #expect(harness.runtime.content(for: contentID) != nil)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func newTabInsertsAfterAMidStripSelection() async {
    let harness = await makeHarness()
    _ = await addTab(harness, title: "Two")
    _ = await addTab(harness, title: "Three")
    let paneID = harness.paneID
    await harness.store.send(.selectTab(id: harness.tabID)) {
      $0.layout.panes[id: paneID]?.selectedTabID = harness.tabID
    }
    let tabID = TerminalTabID()
    let contentID = ContentID()
    await harness.store.send(
      .newTab(inPane: paneID, spec: Self.spec(tabID: tabID, contentID: contentID, title: "After"))
    ) {
      $0.layout.panes[id: paneID]?.tabs.insert(Self.tab(id: tabID, contentID: contentID, title: "After"), at: 1)
      $0.layout.panes[id: paneID]?.selectedTabID = tabID
    }
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func newTabBackgroundStillSelectsWhenPaneHadNoSelection() async {
    let paneID = PaneID()
    let bundle = makeStore(
      layout: PaneLayout(tree: SplitTree(view: paneID), panes: [Pane(id: paneID)], focusedPaneID: paneID)
    )
    let tabID = TerminalTabID()
    let contentID = ContentID()
    await bundle.store.send(
      .newTab(inPane: paneID, spec: Self.spec(tabID: tabID, contentID: contentID, select: false))
    ) {
      $0.layout.panes[id: paneID]?.tabs = [Self.tab(id: tabID, contentID: contentID, title: "Tab")]
      $0.layout.panes[id: paneID]?.selectedTabID = tabID
    }
    #expect(bundle.store.state.layout.isConsistent)
  }

  @Test func newTabIntoEmptyLayoutMaterializesThePane() async {
    let bundle = makeStore(layout: PaneLayout())
    let paneID = PaneID()
    let tabID = TerminalTabID()
    let contentID = ContentID()
    await bundle.store.send(
      .newTab(inPane: paneID, spec: Self.spec(tabID: tabID, contentID: contentID, select: false))
    ) {
      $0.layout = PaneLayout(
        tree: SplitTree(view: paneID),
        panes: [
          Pane(id: paneID, tabs: [Self.tab(id: tabID, contentID: contentID, title: "Tab")], selectedTabID: tabID)
        ],
        focusedPaneID: paneID
      )
    }
    #expect(bundle.runtime.content(for: contentID) != nil)
    #expect(bundle.store.state.layout.isConsistent)
  }

  @Test func newTabProvisionRefusalOnEmptyLayoutLeavesItEmpty() async {
    let bundle = makeStore(layout: PaneLayout())
    let contentID = ContentID()
    // Tombstoned content must not leave a half-materialized root pane behind.
    bundle.runtime.remove(contentID, tombstone: true)
    await bundle.store.send(
      .newTab(inPane: PaneID(), spec: Self.spec(tabID: TerminalTabID(), contentID: contentID))
    )
    #expect(bundle.store.state.layout.panes.isEmpty)
    #expect(bundle.store.state.layout.tree.isEmpty)
    #expect(bundle.store.state.layout.isConsistent)
  }

  @Test func newTabDuplicateTabIDMintsAFreshOne() async {
    let harness = await makeHarness()
    let contentID = ContentID()
    let minted = TerminalTabID(rawValue: UUID(0))
    await harness.store.send(
      .newTab(inPane: harness.paneID, spec: Self.spec(tabID: harness.tabID, contentID: contentID))
    ) {
      $0.layout.panes[id: harness.paneID]?.tabs.insert(Self.tab(id: minted, contentID: contentID, title: "Tab"), at: 1)
      $0.layout.panes[id: harness.paneID]?.selectedTabID = minted
    }
    #expect(harness.runtime.content(for: contentID) != nil)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func newTabDuplicateContentIDIsRefusedBeforeProvisioning() async {
    let harness = await makeHarness()
    await harness.store.send(
      .newTab(inPane: harness.paneID, spec: Self.spec(tabID: TerminalTabID(), contentID: harness.contentID))
    )
    // Only the bootstrap tab ever reached the factory.
    #expect(harness.recorder.madeStates.count == 1)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func newTabIntoUnknownPaneNeverInvokesFactory() async {
    let harness = await makeHarness()
    await harness.store.send(.newTab(inPane: PaneID(), spec: Self.spec()))
    #expect(harness.recorder.madeStates.count == 1)
    #expect(harness.store.state.layout.isConsistent)
  }

  // MARK: - Split pane.

  @Test func splitPaneAddsFocusedPaneAndClearsZoom() async {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID, mintIndex: 0)
    await harness.store.send(.toggleZoom(paneID: split.paneID)) {
      $0.layout.tree = $0.layout.tree.settingZoomed($0.layout.tree.find(id: split.paneID.rawValue))
    }
    let second = await splitPane(harness, anchor: split.paneID, direction: .down, mintIndex: 1, title: "Third")
    #expect(harness.store.state.layout.tree.zoomed == nil)
    #expect(harness.store.state.layout.focusedPaneID == second.paneID)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func splitPaneUnknownAnchorIsRefusedBeforeProvisioning() async {
    let harness = await makeHarness()
    let tabID = TerminalTabID()
    let contentID = ContentID()
    await harness.store.send(
      .splitPane(id: PaneID(), direction: .right, spec: Self.spec(tabID: tabID, contentID: contentID))
    )
    // The anchor pre-check runs before the factory, so no session ever starts.
    #expect(harness.recorder.contents[contentID] == nil)
    #expect(harness.runtime.content(for: contentID) == nil)
    #expect(harness.runtime.pendingKill.isEmpty)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func splitPaneInsertFailureTombstonesTheStartedSession() async {
    // Seeding the pane at UUID(0) makes the minted pane ID collide, forcing
    // the insert to throw after provisioning succeeded.
    let harness = await makeHarness(paneID: PaneID(rawValue: UUID(0)))
    let tabID = TerminalTabID()
    let contentID = ContentID()
    await harness.store.send(
      .splitPane(id: harness.paneID, direction: .right, spec: Self.spec(tabID: tabID, contentID: contentID))
    )
    // Provisioned, then rolled back into the kill path.
    #expect(harness.recorder.contents[contentID] != nil)
    #expect(harness.runtime.content(for: contentID) == nil)
    await harness.store.receive(.runtime(.killConfirmed(id: contentID)))
    #expect(harness.runtime.pendingKill.isEmpty)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func splitPaneWithBackgroundSpecKeepsFocus() async throws {
    let harness = await makeHarness()
    let newPaneID = PaneID(rawValue: UUID(0))
    let tabID = TerminalTabID()
    let contentID = ContentID()
    await harness.store.send(
      .splitPane(
        id: harness.paneID,
        direction: .right,
        spec: Self.spec(tabID: tabID, contentID: contentID, select: false)
      )
    ) {
      $0.layout.tree = try $0.layout.tree.inserting(view: newPaneID, at: harness.paneID, direction: .right)
      $0.layout.panes.append(
        Pane(id: newPaneID, tabs: [Self.tab(id: tabID, contentID: contentID, title: "Tab")], selectedTabID: tabID)
      )
    }
    #expect(harness.store.state.layout.focusedPaneID == harness.paneID)
    #expect(harness.store.state.layout.isConsistent)
  }

  // MARK: - Close tab.

  @Test func closeTabTombstonesAndRetargetsSelection() async {
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let third = await addTab(harness, title: "Three")
    let paneID = harness.paneID
    await harness.store.send(.closeTab(id: third.tabID)) {
      $0.layout.panes[id: paneID]?.tabs.remove(id: third.tabID)
      $0.layout.panes[id: paneID]?.selectedTabID = second.tabID
    }
    #expect(harness.runtime.content(for: third.contentID) == nil)
    await harness.store.receive(.runtime(.killConfirmed(id: third.contentID)))
    await harness.store.send(.selectTab(id: harness.tabID)) {
      $0.layout.panes[id: paneID]?.selectedTabID = harness.tabID
    }
    // Closing the first, selected tab falls back to the first remaining one.
    await harness.store.send(.closeTab(id: harness.tabID)) {
      $0.layout.panes[id: paneID]?.tabs.remove(id: harness.tabID)
      $0.layout.panes[id: paneID]?.selectedTabID = second.tabID
    }
    await harness.store.receive(.runtime(.killConfirmed(id: harness.contentID)))
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func closingLastTabCollapsesPaneAndRetargetsFocus() async {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    await harness.store.send(.closeTab(id: split.tabID)) {
      $0.layout.tree = SplitTree(view: harness.paneID)
      $0.layout.panes.remove(id: split.paneID)
      $0.layout.focusedPaneID = harness.paneID
    }
    await harness.store.receive(.runtime(.killConfirmed(id: split.contentID)))
    #expect(harness.runtime.pendingKill.isEmpty)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func closingABackgroundPanesLastTabKeepsFocus() async {
    let harness = await makeHarness()
    let first = await splitPane(harness, anchor: harness.paneID, mintIndex: 0)
    let second = await splitPane(harness, anchor: first.paneID, direction: .down, mintIndex: 1, title: "Third")
    // Closing unfocused `first` must not move focus off `second`.
    await harness.store.send(.closeTab(id: first.tabID)) {
      let node = $0.layout.tree.find(id: first.paneID.rawValue)
      if let node {
        $0.layout.tree = $0.layout.tree.removing(node)
      }
      $0.layout.panes.remove(id: first.paneID)
    }
    await harness.store.receive(.runtime(.killConfirmed(id: first.contentID)))
    #expect(harness.store.state.layout.focusedPaneID == second.paneID)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func closingTheFinalTabEmptiesTheLayout() async {
    let harness = await makeHarness()
    await harness.store.send(.closeTab(id: harness.tabID)) {
      $0.layout.tree = SplitTree()
      $0.layout.panes = []
      $0.layout.focusedPaneID = nil
    }
    await harness.store.receive(.runtime(.killConfirmed(id: harness.contentID)))
    #expect(harness.runtime.pendingKill.isEmpty)
    // The empty layout is re-enterable: newTab materializes a fresh pane.
    let paneID = PaneID()
    let tabID = TerminalTabID()
    let contentID = ContentID()
    await harness.store.send(.newTab(inPane: paneID, spec: Self.spec(tabID: tabID, contentID: contentID))) {
      $0.layout = PaneLayout(
        tree: SplitTree(view: paneID),
        panes: [
          Pane(id: paneID, tabs: [Self.tab(id: tabID, contentID: contentID, title: "Tab")], selectedTabID: tabID)
        ],
        focusedPaneID: paneID
      )
    }
    #expect(harness.store.state.layout.isConsistent)
  }

  // MARK: - Close pane.

  @Test func closePaneTombstonesEveryTab() async {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    let extraTabID = TerminalTabID()
    let extraContentID = ContentID()
    await harness.store.send(
      .newTab(inPane: split.paneID, spec: Self.spec(tabID: extraTabID, contentID: extraContentID, title: "Extra"))
    ) {
      $0.layout.panes[id: split.paneID]?.tabs.append(
        Self.tab(id: extraTabID, contentID: extraContentID, title: "Extra")
      )
      $0.layout.panes[id: split.paneID]?.selectedTabID = extraTabID
    }
    // Kills are merged, so confirmation order is not defined; assert outcomes.
    harness.store.exhaustivity = .off
    await harness.store.send(.closePane(id: split.paneID)) {
      $0.layout.tree = SplitTree(view: harness.paneID)
      $0.layout.panes.remove(id: split.paneID)
      $0.layout.focusedPaneID = harness.paneID
    }
    #expect(harness.runtime.content(for: split.contentID) == nil)
    #expect(harness.runtime.content(for: extraContentID) == nil)
    await harness.store.finish()
    #expect(harness.runtime.pendingKill.isEmpty)
    #expect(harness.store.state.layout.isConsistent)
  }

  // MARK: - Move tab.

  @Test func moveTabAcrossPanesRepairsBothSelections() async {
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let split = await splitPane(harness, anchor: harness.paneID)
    await harness.store.send(.moveTab(id: second.tabID, toPane: split.paneID, index: 0)) {
      $0.layout.panes[id: harness.paneID]?.tabs.remove(id: second.tabID)
      $0.layout.panes[id: harness.paneID]?.selectedTabID = harness.tabID
      $0.layout.panes[id: split.paneID]?.tabs.insert(
        Self.tab(id: second.tabID, contentID: second.contentID, title: "Two"),
        at: 0
      )
      $0.layout.panes[id: split.paneID]?.selectedTabID = second.tabID
    }
    #expect(harness.store.state.layout.focusedPaneID == split.paneID)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func moveTabEmptyingSourceCollapsesSourcePane() async {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    // Index far beyond the strip clamps to the end.
    await harness.store.send(.moveTab(id: harness.tabID, toPane: split.paneID, index: 5)) {
      $0.layout.tree = SplitTree(view: split.paneID)
      $0.layout.panes.remove(id: harness.paneID)
      $0.layout.panes[id: split.paneID]?.tabs.append(
        Self.tab(id: harness.tabID, contentID: harness.contentID, title: "One")
      )
      $0.layout.panes[id: split.paneID]?.selectedTabID = harness.tabID
    }
    #expect(harness.runtime.content(for: harness.contentID) != nil)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func moveTabWithinPaneReorders() async {
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let third = await addTab(harness, title: "Three")
    let paneID = harness.paneID
    await harness.store.send(.moveTab(id: harness.tabID, toPane: paneID, index: 2)) {
      $0.layout.panes[id: paneID]?.tabs = [
        Self.tab(id: second.tabID, contentID: second.contentID, title: "Two"),
        Self.tab(id: third.tabID, contentID: third.contentID, title: "Three"),
        Self.tab(id: harness.tabID, contentID: harness.contentID, title: "One"),
      ]
      $0.layout.panes[id: paneID]?.selectedTabID = harness.tabID
    }
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func movingABackgroundTabKeepsSourceSelection() async {
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let split = await splitPane(harness, anchor: harness.paneID)
    // Moving unselected "One" must leave the source selection on "Two".
    await harness.store.send(.moveTab(id: harness.tabID, toPane: split.paneID, index: 1)) {
      $0.layout.panes[id: harness.paneID]?.tabs.remove(id: harness.tabID)
      $0.layout.panes[id: split.paneID]?.tabs.insert(
        Self.tab(id: harness.tabID, contentID: harness.contentID, title: "One"),
        at: 1
      )
      $0.layout.panes[id: split.paneID]?.selectedTabID = harness.tabID
    }
    #expect(harness.store.state.layout.panes[id: harness.paneID]?.selectedTabID == second.tabID)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func movingATabToAnUnknownPaneLeavesStateUntouched() async {
    let harness = await makeHarness()
    await harness.store.send(.moveTab(id: harness.tabID, toPane: PaneID(), index: 0))
    #expect(harness.runtime.content(for: harness.contentID) != nil)
    #expect(harness.store.state.layout.isConsistent)
  }

  // MARK: - Selection, focus, and zoom.

  @Test func selectTabSelectsAndFocusesItsPane() async {
    let harness = await makeHarness()
    _ = await splitPane(harness, anchor: harness.paneID)
    await harness.store.send(.selectTab(id: harness.tabID)) {
      $0.layout.focusedPaneID = harness.paneID
    }
    #expect(harness.store.state.layout.panes[id: harness.paneID]?.selectedTabID == harness.tabID)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func focusPaneFollowsZoomAcrossDirectionAndDirectTargets() async {
    let harness = await makeHarness(preserveZoom: true)
    let split = await splitPane(harness, anchor: harness.paneID)
    await harness.store.send(.toggleZoom(paneID: split.paneID)) {
      $0.layout.tree = $0.layout.tree.settingZoomed($0.layout.tree.find(id: split.paneID.rawValue))
    }
    await harness.store.send(.focusPane(.direction(.previous))) {
      $0.layout.focusedPaneID = harness.paneID
      $0.layout.tree = $0.layout.tree.settingZoomed($0.layout.tree.find(id: harness.paneID.rawValue))
    }
    await harness.store.send(.focusPane(.pane(split.paneID))) {
      $0.layout.focusedPaneID = split.paneID
      $0.layout.tree = $0.layout.tree.settingZoomed($0.layout.tree.find(id: split.paneID.rawValue))
    }
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func focusPaneWithoutZoomOnlyMovesFocus() async {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    await harness.store.send(.focusPane(.direction(.previous))) {
      $0.layout.focusedPaneID = harness.paneID
    }
    #expect(harness.store.state.layout.tree.zoomed == nil)
    #expect(harness.store.state.layout.focusedPaneID != split.paneID)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func focusChangeClearsZoomWhenPreservationIsDisabled() async {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    await harness.store.send(.toggleZoom(paneID: split.paneID)) {
      $0.layout.tree = $0.layout.tree.settingZoomed($0.layout.tree.find(id: split.paneID.rawValue))
    }
    // Selecting a tab in the hidden pane unzooms it into view.
    await harness.store.send(.selectTab(id: harness.tabID)) {
      $0.layout.focusedPaneID = harness.paneID
      $0.layout.tree = $0.layout.tree.settingZoomed(nil)
    }
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func selectTabWithinTheZoomedPaneKeepsZoom() async {
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    _ = await splitPane(harness, anchor: harness.paneID)
    await harness.store.send(.toggleZoom(paneID: harness.paneID)) {
      $0.layout.focusedPaneID = harness.paneID
      $0.layout.tree = $0.layout.tree.settingZoomed($0.layout.tree.find(id: harness.paneID.rawValue))
    }
    // Switching tabs inside the zoomed pane is not navigation; zoom stays.
    await harness.store.send(.selectTab(id: harness.tabID)) {
      $0.layout.panes[id: harness.paneID]?.selectedTabID = harness.tabID
    }
    #expect(harness.store.state.layout.tree.zoomed != nil)
    #expect(harness.store.state.layout.panes[id: harness.paneID]?.selectedTabID != second.tabID)
    #expect(harness.store.state.layout.isConsistent)
  }

  // MARK: - Rename.

  @Test func renameTabTrimsAndEmptyRenameClearsOverride() async {
    let harness = await makeHarness()
    let paneID = harness.paneID
    await harness.store.send(.renameTab(id: harness.tabID, title: "  Custom Name  ")) {
      $0.layout.panes[id: paneID]?.tabs[id: harness.tabID]?.customTitle = "Custom Name"
    }
    await harness.store.send(.renameTab(id: harness.tabID, title: "   ")) {
      $0.layout.panes[id: paneID]?.tabs[id: harness.tabID]?.customTitle = nil
    }
    #expect(harness.store.state.layout.panes[id: paneID]?.tabs[id: harness.tabID]?.customTitle == nil)
    #expect(harness.store.state.layout.isConsistent)
  }

  // MARK: - Resize, equalize, zoom.

  @Test func resizePaneClampsRatioAndIgnoresLeaves() async throws {
    let harness = await makeHarness()
    _ = await splitPane(harness, anchor: harness.paneID)
    let root = try #require(harness.store.state.layout.tree.root)
    await harness.store.send(.resizePane(node: root, ratio: 0.97)) {
      $0.layout.tree = try $0.layout.tree.replacing(node: root, with: root.resizing(to: 0.9))
    }
    let widened = try #require(harness.store.state.layout.tree.root)
    await harness.store.send(.resizePane(node: widened, ratio: 0.01)) {
      $0.layout.tree = try $0.layout.tree.replacing(node: widened, with: widened.resizing(to: 0.1))
    }
    // Leaves carry no ratio; the action is a no-op.
    let leaf = try #require(harness.store.state.layout.tree.find(id: harness.paneID.rawValue))
    await harness.store.send(.resizePane(node: leaf, ratio: 0.5))
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func equalizePanesRestoresBalancedRatios() async throws {
    let harness = await makeHarness()
    _ = await splitPane(harness, anchor: harness.paneID)
    let root = try #require(harness.store.state.layout.tree.root)
    await harness.store.send(.resizePane(node: root, ratio: 0.8)) {
      $0.layout.tree = try $0.layout.tree.replacing(node: root, with: root.resizing(to: 0.8))
    }
    await harness.store.send(.equalizePanes) {
      $0.layout.tree = $0.layout.tree.equalized()
    }
    guard case .split(let split) = harness.store.state.layout.tree.root else {
      Issue.record("Expected a split root.")
      return
    }
    #expect(split.ratio == 0.5)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func toggleZoomTogglesTheLeaf() async {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    await harness.store.send(.toggleZoom(paneID: split.paneID)) {
      $0.layout.tree = $0.layout.tree.settingZoomed($0.layout.tree.find(id: split.paneID.rawValue))
    }
    #expect(harness.store.state.layout.tree.zoomed != nil)
    await harness.store.send(.toggleZoom(paneID: split.paneID)) {
      $0.layout.tree = $0.layout.tree.settingZoomed(nil)
    }
    #expect(harness.store.state.layout.tree.zoomed == nil)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func toggleZoomFocusesTheZoomedPane() async {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    // Zooming the unfocused pane must also focus it, or keystrokes would
    // route off-screen.
    await harness.store.send(.toggleZoom(paneID: harness.paneID)) {
      $0.layout.focusedPaneID = harness.paneID
      $0.layout.tree = $0.layout.tree.settingZoomed($0.layout.tree.find(id: harness.paneID.rawValue))
    }
    await harness.store.send(.toggleZoom(paneID: harness.paneID)) {
      $0.layout.tree = $0.layout.tree.settingZoomed(nil)
    }
    #expect(harness.store.state.layout.focusedPaneID == harness.paneID)
    #expect(harness.store.state.layout.focusedPaneID != split.paneID)
    #expect(harness.store.state.layout.isConsistent)
  }

  // MARK: - Hibernate and wake.

  @Test func hibernateTabRefreshesStoredSnapshot() async throws {
    let harness = await makeHarness()
    let grid = try #require(
      FrozenGrid.from(backingSize: CGSize(width: 1024, height: 768), columns: 80, rows: 24, scale: 2, fontSize: nil)
    )
    let marker = TerminalContentState(workingDirectory: "/marker", frozenGrid: grid)
    let mock = try #require(harness.mock)
    mock.snapshotState = marker
    let paneID = harness.paneID
    await harness.store.send(.hibernateTab(id: harness.tabID)) {
      $0.layout.panes[id: paneID]?.tabs[id: harness.tabID]?.content =
        ContentSnapshot(id: harness.contentID, state: .terminal(marker))
    }
    #expect(mock.hibernateCalls == 1)
    #expect(harness.runtime.content(for: harness.contentID) === mock)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func wakeTabRestartsSessionAtRestoredGeometry() async throws {
    let harness = await makeHarness()
    let grid = try #require(
      FrozenGrid.from(backingSize: CGSize(width: 1024, height: 768), columns: 80, rows: 24, scale: 2, fontSize: nil)
    )
    let marker = TerminalContentState(workingDirectory: "/marker", frozenGrid: grid)
    let mock = try #require(harness.mock)
    mock.snapshotState = marker
    await harness.store.send(.hibernateTab(id: harness.tabID)) {
      $0.layout.panes[id: harness.paneID]?.tabs[id: harness.tabID]?.content =
        ContentSnapshot(id: harness.contentID, state: .terminal(marker))
    }
    await harness.store.send(.wakeTab(id: harness.tabID))
    let restored = try #require(ContentGeometry.restored(grid))
    #expect(mock.startGeometries == [.fallback, restored])
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func wakeTabWithoutRuntimeContentProvisionsViaFactory() async throws {
    let harness = await makeHarness()
    let grid = try #require(
      FrozenGrid.from(backingSize: CGSize(width: 1024, height: 768), columns: 80, rows: 24, scale: 2, fontSize: nil)
    )
    let marker = TerminalContentState(workingDirectory: "/marker", frozenGrid: grid)
    let original = try #require(harness.mock)
    original.snapshotState = marker
    await harness.store.send(.hibernateTab(id: harness.tabID)) {
      $0.layout.panes[id: harness.paneID]?.tabs[id: harness.tabID]?.content =
        ContentSnapshot(id: harness.contentID, state: .terminal(marker))
    }
    // Simulate a relaunch: the runtime lost the entry, no tombstone.
    harness.runtime.remove(harness.contentID, tombstone: false)
    await harness.store.send(.wakeTab(id: harness.tabID))
    let revived = try #require(harness.recorder.contents[harness.contentID])
    #expect(revived !== original)
    #expect(harness.recorder.madeStates.last == marker)
    let restored = try #require(ContentGeometry.restored(grid))
    #expect(revived.startGeometries == [restored])
    #expect(harness.runtime.content(for: harness.contentID) === revived)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func wakeTabWithoutAFrozenGridFallsBack() async throws {
    let harness = await makeHarness()
    let custom = try #require(ContentGeometry.candidate(pointSize: CGSize(width: 800, height: 600), scale: 2))
    let tabID = TerminalTabID()
    let contentID = ContentID()
    let paneID = harness.paneID
    await harness.store.send(
      .newTab(inPane: paneID, spec: Self.spec(tabID: tabID, contentID: contentID, geometry: custom))
    ) {
      $0.layout.panes[id: paneID]?.tabs.insert(Self.tab(id: tabID, contentID: contentID, title: "Tab"), at: 1)
      $0.layout.panes[id: paneID]?.selectedTabID = tabID
    }
    let mock = try #require(harness.recorder.contents[contentID])
    // A tab hibernated before its first render records no grid.
    let marker = TerminalContentState(workingDirectory: "/marker")
    mock.snapshotState = marker
    await harness.store.send(.hibernateTab(id: tabID)) {
      $0.layout.panes[id: paneID]?.tabs[id: tabID]?.content =
        ContentSnapshot(id: contentID, state: .terminal(marker))
    }
    await harness.store.send(.wakeTab(id: tabID))
    #expect(mock.startGeometries == [custom, .fallback])
    #expect(harness.store.state.layout.isConsistent)
  }

  // MARK: - Runtime events.

  @Test func killConfirmedClearsTombstoneForReuse() async {
    // Gate the killer so the tombstone window stays observably open until
    // the test releases it.
    let gate = AsyncStream<Void>.makeStream()
    let harness = await makeHarness(
      killer: ContentSessionKiller(
        kill: { _, _ in
          var releases = gate.stream.makeAsyncIterator()
          _ = await releases.next()
        }
      )
    )
    let second = await addTab(harness, title: "Two")
    let paneID = harness.paneID
    await harness.store.send(.closeTab(id: second.tabID)) {
      $0.layout.panes[id: paneID]?.tabs.remove(id: second.tabID)
      $0.layout.panes[id: paneID]?.selectedTabID = harness.tabID
    }
    // The kill is suspended: the tombstone must hold the identity hostage.
    #expect(harness.runtime.pendingKill.contains(second.contentID))
    gate.continuation.yield()
    await harness.store.receive(.runtime(.killConfirmed(id: second.contentID)))
    #expect(harness.runtime.pendingKill.isEmpty)
    // The identity is reusable again once the kill is confirmed.
    let reusedTabID = TerminalTabID()
    await harness.store.send(
      .newTab(inPane: paneID, spec: Self.spec(tabID: reusedTabID, contentID: second.contentID, title: "Reborn"))
    ) {
      $0.layout.panes[id: paneID]?.tabs.insert(
        Self.tab(id: reusedTabID, contentID: second.contentID, title: "Reborn"),
        at: 1
      )
      $0.layout.panes[id: paneID]?.selectedTabID = reusedTabID
    }
    #expect(harness.runtime.content(for: second.contentID) != nil)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func titleChangedUpdatesTitleNotCustomTitle() async {
    let harness = await makeHarness()
    let paneID = harness.paneID
    await harness.store.send(.renameTab(id: harness.tabID, title: "Custom")) {
      $0.layout.panes[id: paneID]?.tabs[id: harness.tabID]?.customTitle = "Custom"
    }
    await harness.store.send(.runtime(.titleChanged(id: harness.contentID, title: "zsh"))) {
      $0.layout.panes[id: paneID]?.tabs[id: harness.tabID]?.title = "zsh"
    }
    #expect(harness.store.state.layout.panes[id: paneID]?.tabs[id: harness.tabID]?.customTitle == "Custom")
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func closeTabKillsTheSessionOfItsWorktree() async {
    let killed = LockIsolated<[(content: ContentID, worktree: Worktree.ID)]>([])
    let harness = await makeHarness(
      killer: ContentSessionKiller(
        kill: { content, worktree in
          killed.withValue { $0.append((content: content, worktree: worktree)) }
        }
      )
    )
    await harness.store.send(.closeTab(id: harness.tabID)) {
      $0.layout.tree = SplitTree()
      $0.layout.panes = []
      $0.layout.focusedPaneID = nil
    }
    await harness.store.receive(.runtime(.killConfirmed(id: harness.contentID)))
    #expect(killed.value.count == 1)
    #expect(killed.value.first?.content == harness.contentID)
    #expect(killed.value.first?.worktree == WorktreeID("/tmp/layout-feature"))
  }

  @Test func titleChangedWithTheSameTitleIsANoOp() async {
    let harness = await makeHarness()
    // The bootstrap tab is titled "One"; an identical report must not write.
    await harness.store.send(.runtime(.titleChanged(id: harness.contentID, title: "One")))
    #expect(harness.store.state.layout.isConsistent)
  }
}
