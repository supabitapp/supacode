import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
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
    /// Drives the busy-gated close confirmation in tests.
    var isBusy = false
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

  /// Factory stand-in recording every created content and its request.
  @MainActor
  private final class ContentRecorder {
    private(set) var contents: [ContentID: MockTabContent] = [:]
    private(set) var requests: [ContentRequest] = []

    var madeStates: [TerminalContentState] { requests.map { Self.terminalState(of: $0.content) } }

    static func terminalState(of content: ContentState) -> TerminalContentState {
      guard case .terminal(let state) = content else { return TerminalContentState(workingDirectory: nil) }
      return state
    }

    func make(_ request: ContentRequest) -> any TabContent {
      let content = MockTabContent(id: request.contentID, initialState: Self.terminalState(of: request.content))
      contents[request.contentID] = content
      requests.append(request)
      return content
    }
  }

  private struct Harness {
    let store: TestStoreOf<LayoutFeature>
    let runtime: ContentRuntime
    let recorder: ContentRecorder
    let paneID: PaneID
    let tabID: TabID
    let contentID: ContentID

    var mock: MockTabContent? { recorder.contents[contentID] }
  }

  // MARK: - Helpers.

  private static let seedState = TerminalContentState(workingDirectory: "/tmp/layout-feature")

  private static func spec(
    tabID: TabID? = nil,
    contentID: ContentID? = nil,
    title: String = "Tab",
    geometry: ContentGeometry = .fallback,
    select: Bool = true
  ) -> NewTabSpec {
    NewTabSpec(
      tabID: tabID,
      contentID: contentID,
      title: title,
      content: .terminal(seedState),
      geometry: geometry,
      select: select
    )
  }

  private static func tab(
    id tabID: TabID,
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
        make: { request in recorder.make(request) }
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
    let tabID = TabID()
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
  ) async -> (tabID: TabID, contentID: ContentID) {
    let tabID = TabID()
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

  /// Puts the pane in window mode, asserting only the flag flip.
  private func enterWindowMode(_ harness: Harness, paneID: PaneID) async {
    await harness.store.send(.enterWindowMode(paneID: paneID)) {
      $0.windowedPaneIDs.insert(paneID)
    }
  }

  private struct SplitResult {
    let paneID: PaneID
    let tabID: TabID
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
    let tabID = TabID()
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
    let tabID = TabID()
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
    #expect(harness.recorder.requests.last?.origin == .tab)
    #expect(harness.recorder.requests.last?.tabID == tabID)
    #expect(harness.runtime.content(for: contentID) === mock)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func newTabProvisionRefusalLeavesStateUntouched() async {
    let harness = await makeHarness()
    let contentID = ContentID()
    // Tombstone the identity up front so the runtime refuses to provision it.
    harness.runtime.remove(contentID, tombstone: true)
    await harness.store.send(
      .newTab(inPane: harness.paneID, spec: Self.spec(tabID: TabID(), contentID: contentID))
    )
    #expect(harness.recorder.contents[contentID]?.startGeometries.isEmpty == true)
    #expect(harness.runtime.content(for: contentID) == nil)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func newTabBackgroundAppendsWithoutTakingSelectionOrFocus() async {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    let tabID = TabID()
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
    let tabID = TabID()
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
    let tabID = TabID()
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
    let tabID = TabID()
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
    #expect(bundle.recorder.requests.last?.origin == .first)
    #expect(bundle.store.state.layout.isConsistent)
  }

  @Test func newTabProvisionRefusalOnEmptyLayoutLeavesItEmpty() async {
    let bundle = makeStore(layout: PaneLayout())
    let contentID = ContentID()
    // Tombstoned content must not leave a half-materialized root pane behind.
    bundle.runtime.remove(contentID, tombstone: true)
    await bundle.store.send(
      .newTab(inPane: PaneID(), spec: Self.spec(tabID: TabID(), contentID: contentID))
    )
    #expect(bundle.store.state.layout.panes.isEmpty)
    #expect(bundle.store.state.layout.tree.isEmpty)
    #expect(bundle.store.state.layout.isConsistent)
  }

  @Test func newTabDuplicateTabIDMintsAFreshOne() async {
    let harness = await makeHarness()
    let contentID = ContentID()
    let minted = TabID(rawValue: UUID(0))
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
      .newTab(inPane: harness.paneID, spec: Self.spec(tabID: TabID(), contentID: harness.contentID))
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
    #expect(harness.recorder.requests.last?.origin == .split)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func splitPaneUnknownAnchorIsRefusedBeforeProvisioning() async {
    let harness = await makeHarness()
    let tabID = TabID()
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
    let tabID = TabID()
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
    let tabID = TabID()
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
    let tabID = TabID()
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
    let extraTabID = TabID()
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

  @Test func backgroundMoveToSplitLeavesFocusOnTheSourcePane() async {
    let harness = await makeHarness()
    _ = await addTab(harness, title: "Two")
    harness.store.exhaustivity = .off
    let sourcePane = harness.paneID
    // A background move (select: false) must not steal focus to the new pane;
    // a foreground move would.
    await harness.store.send(
      .moveTabToSplit(id: harness.tabID, anchor: sourcePane, direction: .right, select: false))
    #expect(harness.store.state.layout.focusedPaneID == sourcePane)
    #expect(harness.store.state.layout.panes.count == 2)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func spanningMoveWrapsBothPanesInANewSplit() async {
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    _ = await splitPane(harness, anchor: harness.paneID)
    harness.store.exhaustivity = .off
    // A divider-adjacent drop spans both panes: the whole parent split is
    // wrapped in a new perpendicular split, so a third pane appears above it.
    await harness.store.send(
      .moveTabToSpanningSplit(id: second.tabID, anchor: harness.paneID, direction: .top))
    let layout = harness.store.state.layout
    #expect(layout.panes.count == 3)
    if case .split(let outer) = layout.tree.root {
      #expect(outer.direction == .vertical)
    } else {
      Issue.record("expected a spanning vertical root split")
    }
    // The moved tab lands in the fresh spanning pane, which takes focus; the
    // source keeps its remaining tab.
    let spanPane = layout.pane(containingTab: second.tabID)
    #expect(spanPane != nil)
    #expect(spanPane?.id != harness.paneID)
    #expect(spanPane?.id == layout.focusedPaneID)
    #expect(layout.panes[id: harness.paneID]?.tabs.ids.contains(harness.tabID) == true)
    #expect(layout.isConsistent)
  }

  @Test func spanningMoveOfThePanesOnlyTabOntoItselfIsRefused() async {
    let harness = await makeHarness()
    // A parent split rules out the root-leaf throw, isolating the single-tab guard.
    _ = await splitPane(harness, anchor: harness.paneID)
    await harness.store.send(
      .moveTabToSpanningSplit(id: harness.tabID, anchor: harness.paneID, direction: .down))
    #expect(harness.store.state.layout.panes.count == 2)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func spanningMoveAtAWindowedAnchorIsRefused() async {
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let split = await splitPane(harness, anchor: harness.paneID)
    await enterWindowMode(harness, paneID: split.paneID)
    await harness.store.send(
      .moveTabToSpanningSplit(id: second.tabID, anchor: split.paneID, direction: .left))
    #expect(harness.store.state.layout.panes.count == 2)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func spanningMoveAtAnUnknownAnchorIsRefused() async {
    let harness = await makeHarness()
    await harness.store.send(
      .moveTabToSpanningSplit(id: harness.tabID, anchor: PaneID(), direction: .top))
    #expect(harness.store.state.layout.panes.count == 1)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func spanningMoveWithNoParentSplitIsRefused() async {
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    // The sole pane is the root leaf, so the span insert throws and no-ops.
    await harness.store.send(
      .moveTabToSpanningSplit(id: second.tabID, anchor: harness.paneID, direction: .top))
    #expect(harness.store.state.layout.panes.count == 1)
    #expect(harness.store.state.layout.panes[id: harness.paneID]?.tabs.count == 2)
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

  // MARK: - Move to split (drag-to-split drop zones).

  @Test func moveTabToSplitCreatesAPaneWithTheMovedTab() async {
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let split = await splitPane(harness, anchor: harness.paneID)
    let newPaneID = PaneID(rawValue: UUID(1))
    await harness.store.send(.moveTabToSplit(id: second.tabID, anchor: split.paneID, direction: .down)) {
      $0.layout.tree = try $0.layout.tree.inserting(view: newPaneID, at: split.paneID, direction: .down)
      $0.layout.panes[id: harness.paneID]?.tabs.remove(id: second.tabID)
      $0.layout.panes[id: harness.paneID]?.selectedTabID = harness.tabID
      $0.layout.panes.append(
        Pane(
          id: newPaneID,
          tabs: [Self.tab(id: second.tabID, contentID: second.contentID, title: "Two")],
          selectedTabID: second.tabID
        )
      )
      $0.layout.focusedPaneID = newPaneID
    }
    // The moved content keeps its live session; nothing reaps.
    #expect(harness.runtime.content(for: second.contentID) != nil)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func moveTabToSplitEmptyingSourceCollapsesIt() async {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    let newPaneID = PaneID(rawValue: UUID(1))
    await harness.store.send(.moveTabToSplit(id: harness.tabID, anchor: split.paneID, direction: .right)) {
      var tree = try $0.layout.tree.inserting(view: newPaneID, at: split.paneID, direction: .right)
      if let node = tree.find(id: harness.paneID.rawValue) {
        tree = tree.removing(node)
      }
      $0.layout.tree = tree
      $0.layout.panes.remove(id: harness.paneID)
      $0.layout.panes.append(
        Pane(
          id: newPaneID,
          tabs: [Self.tab(id: harness.tabID, contentID: harness.contentID, title: "One")],
          selectedTabID: harness.tabID
        )
      )
      $0.layout.focusedPaneID = newPaneID
    }
    #expect(harness.runtime.content(for: harness.contentID) != nil)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func moveTabToSplitOfThePanesOnlyTabOntoItselfIsRefused() async {
    let harness = await makeHarness()
    await harness.store.send(.moveTabToSplit(id: harness.tabID, anchor: harness.paneID, direction: .left))
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func moveTabToSplitAtAWindowedAnchorIsRefused() async {
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let split = await splitPane(harness, anchor: harness.paneID)
    await enterWindowMode(harness, paneID: split.paneID)
    await harness.store.send(.moveTabToSplit(id: second.tabID, anchor: split.paneID, direction: .down))
    #expect(harness.store.state.layout.isConsistent)
  }

  // MARK: - Window mode.

  @Test func enterWindowModeMarksThePaneAndDropsItsZoom() async {
    let harness = await makeHarness()
    _ = await splitPane(harness, anchor: harness.paneID)
    await harness.store.send(.toggleZoom(paneID: harness.paneID)) {
      $0.layout.focusedPaneID = harness.paneID
      $0.layout.tree = $0.layout.tree.settingZoomed($0.layout.tree.find(id: harness.paneID.rawValue))
    }
    await harness.store.send(.enterWindowMode(paneID: harness.paneID)) {
      $0.layout.tree = $0.layout.tree.settingZoomed(nil)
      $0.windowedPaneIDs = [harness.paneID]
    }
    // Window mode relocates the surface; it never touches the session.
    #expect(harness.runtime.content(for: harness.contentID) != nil)
    #expect(harness.runtime.pendingKill.isEmpty)
    #expect(harness.mock?.startCalls == 1)
    // The windowed pane keeps focus, which is what makes the split and zoom
    // guards load-bearing.
    #expect(harness.store.state.layout.focusedPaneID == harness.paneID)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func exitWindowModeClearsTheFlag() async {
    let harness = await makeHarness()
    await enterWindowMode(harness, paneID: harness.paneID)
    await harness.store.send(.exitWindowMode(paneID: harness.paneID)) {
      $0.windowedPaneIDs = []
    }
    #expect(harness.runtime.content(for: harness.contentID) != nil)
    #expect(harness.runtime.pendingKill.isEmpty)
    #expect(harness.mock?.startCalls == 1)
  }

  @Test func exitWindowModeForAPaneThatIsNotWindowedIsANoOp() async {
    let harness = await makeHarness()
    // A stray window-close callback for an already-reattached pane is
    // harmless, whether the pane exists or not.
    await harness.store.send(.exitWindowMode(paneID: harness.paneID))
    await harness.store.send(.exitWindowMode(paneID: PaneID()))
  }

  @Test func enterWindowModeForAnUnknownPaneIsRefused() async {
    let harness = await makeHarness()
    await harness.store.send(.enterWindowMode(paneID: PaneID()))
  }

  @Test func splitPaneAtAWindowedAnchorIsRefusedBeforeProvisioning() async {
    let harness = await makeHarness()
    await enterWindowMode(harness, paneID: harness.paneID)
    await harness.store.send(.splitPane(id: harness.paneID, direction: .right, spec: Self.spec()))
    // Refused before the factory ran: only the harness bootstrap exists.
    #expect(harness.recorder.requests.count == 1)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func toggleZoomOnAWindowedPaneIsRefused() async {
    let harness = await makeHarness()
    _ = await splitPane(harness, anchor: harness.paneID)
    await enterWindowMode(harness, paneID: harness.paneID)
    await harness.store.send(.toggleZoom(paneID: harness.paneID))
    #expect(harness.store.state.layout.tree.zoomed == nil)
  }

  @Test func closingAWindowedPanesLastTabClearsTheFlag() async {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    await enterWindowMode(harness, paneID: split.paneID)
    await harness.store.send(.closeTab(id: split.tabID)) {
      $0.layout.tree = SplitTree(view: harness.paneID)
      $0.layout.panes.remove(id: split.paneID)
      $0.layout.focusedPaneID = harness.paneID
      $0.windowedPaneIDs = []
    }
    await harness.store.receive(.runtime(.killConfirmed(id: split.contentID)))
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func moveTabToSplitOffItsOwnPaneKeepsTheRemainingTabs() async {
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let newPaneID = PaneID(rawValue: UUID(0))
    await harness.store.send(.moveTabToSplit(id: second.tabID, anchor: harness.paneID, direction: .right)) {
      $0.layout.tree = try $0.layout.tree.inserting(view: newPaneID, at: harness.paneID, direction: .right)
      $0.layout.panes[id: harness.paneID]?.tabs.remove(id: second.tabID)
      $0.layout.panes[id: harness.paneID]?.selectedTabID = harness.tabID
      $0.layout.panes.append(
        Pane(
          id: newPaneID,
          tabs: [Self.tab(id: second.tabID, contentID: second.contentID, title: "Two")],
          selectedTabID: second.tabID
        )
      )
      $0.layout.focusedPaneID = newPaneID
    }
    #expect(harness.store.state.layout.tree.visibleLeaves() == [harness.paneID, newPaneID])
    #expect(harness.runtime.content(for: second.contentID) != nil)
  }

  @Test func movingABackgroundTabToASplitKeepsSourceSelection() async {
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let split = await splitPane(harness, anchor: harness.paneID)
    let newPaneID = PaneID(rawValue: UUID(1))
    // Moving unselected "One" must leave the source selection on "Two".
    await harness.store.send(.moveTabToSplit(id: harness.tabID, anchor: split.paneID, direction: .down)) {
      $0.layout.tree = try $0.layout.tree.inserting(view: newPaneID, at: split.paneID, direction: .down)
      $0.layout.panes[id: harness.paneID]?.tabs.remove(id: harness.tabID)
      $0.layout.panes.append(
        Pane(
          id: newPaneID,
          tabs: [Self.tab(id: harness.tabID, contentID: harness.contentID, title: "One")],
          selectedTabID: harness.tabID
        )
      )
      $0.layout.focusedPaneID = newPaneID
    }
    #expect(harness.store.state.layout.panes[id: harness.paneID]?.selectedTabID == second.tabID)
  }

  @Test func movingTheSelectedFirstTabToASplitRetargetsToTheNextTab() async {
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let paneID = harness.paneID
    await harness.store.send(.selectTab(id: harness.tabID)) {
      $0.layout.panes[id: paneID]?.selectedTabID = harness.tabID
    }
    let newPaneID = PaneID(rawValue: UUID(0))
    // Removing index 0 retargets the source selection to the first survivor.
    await harness.store.send(.moveTabToSplit(id: harness.tabID, anchor: paneID, direction: .down)) {
      $0.layout.tree = try $0.layout.tree.inserting(view: newPaneID, at: paneID, direction: .down)
      $0.layout.panes[id: paneID]?.tabs.remove(id: harness.tabID)
      $0.layout.panes[id: paneID]?.selectedTabID = second.tabID
      $0.layout.panes.append(
        Pane(
          id: newPaneID,
          tabs: [Self.tab(id: harness.tabID, contentID: harness.contentID, title: "One")],
          selectedTabID: harness.tabID
        )
      )
      $0.layout.focusedPaneID = newPaneID
    }
    #expect(harness.store.state.layout.panes[id: paneID]?.selectedTabID == second.tabID)
  }

  @Test func moveTabToSplitLeftPlacesTheNewPaneBeforeTheAnchor() async {
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let newPaneID = PaneID(rawValue: UUID(0))
    await harness.store.send(.moveTabToSplit(id: second.tabID, anchor: harness.paneID, direction: .left)) {
      $0.layout.tree = try $0.layout.tree.inserting(view: newPaneID, at: harness.paneID, direction: .left)
      $0.layout.panes[id: harness.paneID]?.tabs.remove(id: second.tabID)
      $0.layout.panes[id: harness.paneID]?.selectedTabID = harness.tabID
      $0.layout.panes.append(
        Pane(
          id: newPaneID,
          tabs: [Self.tab(id: second.tabID, contentID: second.contentID, title: "Two")],
          selectedTabID: second.tabID
        )
      )
      $0.layout.focusedPaneID = newPaneID
    }
    // Leaves read in layout order; a leading drop must precede its anchor.
    #expect(harness.store.state.layout.tree.visibleLeaves() == [newPaneID, harness.paneID])
  }

  @Test func moveTabToSplitClearsZoomSoTheNewPaneIsVisible() async {
    // Zoom must drop even under the preserve-on-navigation policy.
    let harness = await makeHarness(preserveZoom: true)
    let second = await addTab(harness, title: "Two")
    let split = await splitPane(harness, anchor: harness.paneID)
    await harness.store.send(.toggleZoom(paneID: split.paneID)) {
      $0.layout.tree = $0.layout.tree.settingZoomed($0.layout.tree.find(id: split.paneID.rawValue))
    }
    let newPaneID = PaneID(rawValue: UUID(1))
    await harness.store.send(.moveTabToSplit(id: second.tabID, anchor: split.paneID, direction: .down)) {
      $0.layout.tree = try $0.layout.tree.settingZoomed(nil)
        .inserting(view: newPaneID, at: split.paneID, direction: .down)
      $0.layout.panes[id: harness.paneID]?.tabs.remove(id: second.tabID)
      $0.layout.panes[id: harness.paneID]?.selectedTabID = harness.tabID
      $0.layout.panes.append(
        Pane(
          id: newPaneID,
          tabs: [Self.tab(id: second.tabID, contentID: second.contentID, title: "Two")],
          selectedTabID: second.tabID
        )
      )
      $0.layout.focusedPaneID = newPaneID
    }
    #expect(harness.store.state.layout.tree.zoomed == nil)
  }

  @Test(.dependencies) func exitWindowModeCancelsThePanesPendingConfirmation() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .always }
    let harness = await makeHarness()
    await enterWindowMode(harness, paneID: harness.paneID)
    await harness.store.send(.contentRequestedClose(content: harness.contentID, scope: .tab)) {
      $0.alertPaneID = harness.paneID
      $0.alert = self.closeConfirmAlert(tabs: [harness.tabID], interrupts: false)
    }
    // The presenting window closes with the exit; a surviving alert would
    // re-materialize as a phantom.
    await harness.store.send(.exitWindowMode(paneID: harness.paneID)) {
      $0.windowedPaneIDs = []
      $0.alertPaneID = nil
      $0.alert = nil
    }
    #expect(harness.store.state.layout.panes[id: harness.paneID]?.tabs[id: harness.tabID] != nil)
  }

  @Test(.dependencies) func enterWindowModeCancelsThePanesPendingConfirmation() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .always }
    let harness = await makeHarness()
    await harness.store.send(.contentRequestedClose(content: harness.contentID, scope: .tab)) {
      $0.alertPaneID = harness.paneID
      $0.alert = self.closeConfirmAlert(tabs: [harness.tabID], interrupts: false)
    }
    // The alert host swaps windows with the pane; the confirmation cancels
    // rather than strand.
    await harness.store.send(.enterWindowMode(paneID: harness.paneID)) {
      $0.windowedPaneIDs = [harness.paneID]
      $0.alertPaneID = nil
      $0.alert = nil
    }
    #expect(harness.store.state.layout.panes[id: harness.paneID]?.tabs[id: harness.tabID] != nil)
  }

  @Test(.dependencies) func collapsingAnAlertOwningPaneClearsTheStrandedAlert() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .always }
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    // Raise a close confirmation owned by the source pane.
    await harness.store.send(.contentRequestedClose(content: harness.contentID, scope: .tab)) {
      $0.alertPaneID = harness.paneID
      $0.alert = self.closeConfirmAlert(tabs: [harness.tabID], interrupts: false)
    }
    harness.store.exhaustivity = .off
    // Collapsing that pane while another survives must drop the alert, or it
    // strands on a removed pane and defers hibernation forever.
    await harness.store.send(.closePane(id: harness.paneID))
    #expect(harness.store.state.alert == nil)
    #expect(harness.store.state.alertPaneID == nil)
    #expect(harness.store.state.layout.panes.count == 1)
    #expect(harness.store.state.layout.panes[id: split.paneID] != nil)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func directionalFocusSkipsWindowedLeavesToTheNextEmbeddedPane() async {
    let harness = await makeHarness()
    let middle = await splitPane(harness, anchor: harness.paneID, mintIndex: 0)
    let far = await splitPane(harness, anchor: middle.paneID, mintIndex: 1, title: "Third")
    await enterWindowMode(harness, paneID: middle.paneID)
    // Focus sits on the far pane; walking back must skip the windowed
    // placeholder and land on the first pane, not dead-end.
    await harness.store.send(.focusPane(.direction(.previous))) {
      $0.layout.focusedPaneID = harness.paneID
    }
  }

  @Test func focusingAWindowedPaneLeavesTheMainTreesZoomAlone() async {
    // Preserve-on-navigation would otherwise retarget the zoom onto the
    // windowed placeholder, filling the main window with it.
    let harness = await makeHarness(preserveZoom: true)
    let split = await splitPane(harness, anchor: harness.paneID)
    await enterWindowMode(harness, paneID: harness.paneID)
    await harness.store.send(.toggleZoom(paneID: split.paneID)) {
      $0.layout.tree = $0.layout.tree.settingZoomed($0.layout.tree.find(id: split.paneID.rawValue))
    }
    // The pane window taking key focuses its pane; the embedded zoom stays.
    await harness.store.send(.focusPane(.pane(harness.paneID))) {
      $0.layout.focusedPaneID = harness.paneID
    }
    #expect(harness.store.state.layout.tree.zoomed != nil)
  }

  @Test func focusSplitFromAWindowedPaneIsRefused() async {
    let harness = await makeHarness()
    _ = await splitPane(harness, anchor: harness.paneID)
    await enterWindowMode(harness, paneID: harness.paneID)
    // A pane window has no neighbors; the request must not walk the main tree.
    await harness.store.send(.contentRequestedFocusSplit(content: harness.contentID, direction: .next))
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func directionalFocusOntoAWindowedPaneIsRefused() async {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    await enterWindowMode(harness, paneID: harness.paneID)
    // Focus sits on the split pane; walking toward the windowed placeholder
    // must not land on it.
    await harness.store.send(.focusPane(.direction(.previous)))
    #expect(harness.store.state.layout.focusedPaneID == split.paneID)
  }

  @Test func resizeFromAWindowedPaneIsRefused() async {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    // Real extents, so the refusal is the guard and not a degenerate total.
    harness.recorder.contents[harness.contentID]?.renderer?.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    harness.recorder.contents[split.contentID]?.renderer?.frame = NSRect(x: 800, y: 0, width: 800, height: 600)
    await enterWindowMode(harness, paneID: harness.paneID)
    // A pane window has no dividers; the request must not resize the main tree.
    await harness.store.send(.contentRequestedResize(content: harness.contentID, direction: .right, amount: 10))
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

  @Test func beginTabRenameOpensTheFieldAndEndCloses() async {
    let harness = await makeHarness()
    await harness.store.send(.beginTabRename(id: harness.tabID)) {
      $0.editingTabID = harness.tabID
    }
    await harness.store.send(.endTabRename) {
      $0.editingTabID = nil
    }
    // An unknown tab must not open a field pointing at nothing.
    await harness.store.send(.beginTabRename(id: TabID()))
  }

  @Test func beginTabRenameRefusesALockedTitle() async {
    let harness = await makeHarness()
    let paneID = harness.paneID
    var locked = harness.store.state.layout
    locked.panes[id: paneID]?.tabs[id: harness.tabID]?.isLocked = true
    let bundle = makeStore(layout: locked)
    await bundle.store.send(.beginTabRename(id: harness.tabID))
    #expect(bundle.store.state.editingTabID == nil)
  }

  @Test(.dependencies) func closingTheEditingTabEndsTheRename() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .never }
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let paneID = harness.paneID
    await harness.store.send(.beginTabRename(id: second.tabID)) {
      $0.editingTabID = second.tabID
    }
    await harness.store.send(.closeTab(id: second.tabID)) {
      $0.editingTabID = nil
      $0.layout.panes[id: paneID]?.tabs.remove(id: second.tabID)
      $0.layout.panes[id: paneID]?.selectedTabID = harness.tabID
    }
    await harness.store.receive(.runtime(.killConfirmed(id: second.contentID)))
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
      $0.renderEpoch = 1
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
      $0.renderEpoch = 1
    }
    await harness.store.send(.wakeTab(id: harness.tabID)) {
      $0.renderEpoch = 2
    }
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
      $0.renderEpoch = 1
    }
    // Simulate a relaunch: the runtime lost the entry, no tombstone.
    harness.runtime.remove(harness.contentID, tombstone: false)
    await harness.store.send(.wakeTab(id: harness.tabID)) {
      $0.renderEpoch = 2
    }
    let revived = try #require(harness.recorder.contents[harness.contentID])
    #expect(revived !== original)
    #expect(harness.recorder.madeStates.last == marker)
    #expect(harness.recorder.requests.last?.origin == .restored)
    #expect(harness.recorder.requests.last?.tabID == harness.tabID)
    let restored = try #require(ContentGeometry.restored(grid))
    #expect(revived.startGeometries == [restored])
    #expect(harness.runtime.content(for: harness.contentID) === revived)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func wakeTabWithoutAFrozenGridFallsBack() async throws {
    let harness = await makeHarness()
    let custom = try #require(ContentGeometry.candidate(pointSize: CGSize(width: 800, height: 600), scale: 2))
    let tabID = TabID()
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
      $0.renderEpoch = 1
    }
    await harness.store.send(.wakeTab(id: tabID)) {
      $0.renderEpoch = 2
    }
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
    let reusedTabID = TabID()
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

  @Test func titleCommittedUpdatesTitleNotCustomTitle() async {
    let harness = await makeHarness()
    let paneID = harness.paneID
    await harness.store.send(.renameTab(id: harness.tabID, title: "Custom")) {
      $0.layout.panes[id: paneID]?.tabs[id: harness.tabID]?.customTitle = "Custom"
    }
    // The commit is what survives the content leaving the runtime, so it lands
    // on the layout's own title, never on the user's override.
    await harness.store.send(.runtime(.titleCommitted(id: harness.contentID, title: "zsh"))) {
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

  @Test func titleCommittedWithTheSameTitleIsANoOp() async {
    let harness = await makeHarness()
    // The bootstrap tab is titled "One"; an identical commit must not write.
    await harness.store.send(.runtime(.titleCommitted(id: harness.contentID, title: "One")))
    #expect(harness.store.state.layout.isConsistent)
  }

  // MARK: - Close confirmation.

  private func closeConfirmAlert(
    tabs tabIDs: [TabID],
    interrupts: Bool = true
  ) -> AlertState<LayoutFeature.Action.Alert> {
    let message: String =
      switch (interrupts, tabIDs.count == 1) {
      case (true, true): "This tab has work that closing would interrupt."
      case (true, false): "These tabs have work that closing would interrupt."
      case (false, true): "Closing will end this tab's session."
      case (false, false): "Closing will end these tabs' sessions."
      }
    return AlertState {
      TextState(tabIDs.count == 1 ? "Close Tab?" : "Close \(tabIDs.count) Tabs?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmClose(tabs: tabIDs)) {
        TextState("Close")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState(message)
    }
  }

  @Test(.dependencies) func contentRequestedCloseAlwaysConfirms() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .always }
    let harness = await makeHarness()
    // Not busy, but `.always` still raises the confirmation.
    await harness.store.send(.contentRequestedClose(content: harness.contentID, scope: .tab)) {
      $0.alertPaneID = harness.paneID
      $0.alert = self.closeConfirmAlert(tabs: [harness.tabID], interrupts: false)
    }
    // Confirming closes the tab and reaps the session.
    await harness.store.send(.alert(.presented(.confirmClose(tabs: [harness.tabID])))) {
      $0.alertPaneID = nil
      $0.alert = nil
      $0.layout.tree = SplitTree()
      $0.layout.panes = []
      $0.layout.focusedPaneID = nil
    }
    await harness.store.receive(.runtime(.killConfirmed(id: harness.contentID)))
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test(.dependencies) func contentRequestedCloseCancelKeepsTheTab() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .always }
    let harness = await makeHarness()
    await harness.store.send(.contentRequestedClose(content: harness.contentID, scope: .tab)) {
      $0.alertPaneID = harness.paneID
      $0.alert = self.closeConfirmAlert(tabs: [harness.tabID], interrupts: false)
    }
    await harness.store.send(.alert(.dismiss)) {
      $0.alertPaneID = nil
      $0.alert = nil
    }
    #expect(harness.store.state.layout.panes[id: harness.paneID]?.tabs[id: harness.tabID] != nil)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test(.dependencies) func contentRequestedCloseNeverSkipsConfirmation() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .never }
    let harness = await makeHarness()
    harness.mock?.isBusy = true
    // `.never` closes immediately even while busy.
    await harness.store.send(.contentRequestedClose(content: harness.contentID, scope: .tab)) {
      $0.layout.tree = SplitTree()
      $0.layout.panes = []
      $0.layout.focusedPaneID = nil
    }
    await harness.store.receive(.runtime(.killConfirmed(id: harness.contentID)))
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test(.dependencies) func contentRequestedCloseBusyConfirmsOnlyWhenBusy() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .busy }
    let harness = await makeHarness()
    harness.mock?.isBusy = true
    await harness.store.send(.contentRequestedClose(content: harness.contentID, scope: .tab)) {
      $0.alertPaneID = harness.paneID
      $0.alert = self.closeConfirmAlert(tabs: [harness.tabID])
    }
  }

  @Test(.dependencies) func contentRequestedCloseBusyClosesWhenIdle() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .busy }
    let harness = await makeHarness()
    harness.mock?.isBusy = false
    await harness.store.send(.contentRequestedClose(content: harness.contentID, scope: .tab)) {
      $0.layout.tree = SplitTree()
      $0.layout.panes = []
      $0.layout.focusedPaneID = nil
    }
    await harness.store.receive(.runtime(.killConfirmed(id: harness.contentID)))
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test(.dependencies) func contentRequestedCloseBusyConfirmsForHibernatedTerminals() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .busy }
    let harness = await makeHarness()
    // A hibernated terminal cannot report busyness; its zmx session may still
    // host work, so busy mode confirms.
    await harness.store.send(.hibernateTab(id: harness.tabID)) {
      $0.renderEpoch = 1
    }
    await harness.store.send(.contentRequestedClose(content: harness.contentID, scope: .tab)) {
      $0.alertPaneID = harness.paneID
      $0.alert = self.closeConfirmAlert(tabs: [harness.tabID])
    }
  }

  @Test(.dependencies) func contentRequestedCloseOtherTabsScopesToThePane() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .never }
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let third = await addTab(harness, title: "Three")
    let paneID = harness.paneID
    // Closing others from the first tab drops the second and third only.
    await harness.store.send(.contentRequestedClose(content: harness.contentID, scope: .otherTabs)) {
      $0.layout.panes[id: paneID]?.tabs.remove(id: second.tabID)
      $0.layout.panes[id: paneID]?.tabs.remove(id: third.tabID)
      $0.layout.panes[id: paneID]?.selectedTabID = harness.tabID
    }
    // The merged reaps confirm in no guaranteed order.
    harness.store.exhaustivity = .off
    await harness.store.finish()
    #expect(harness.runtime.pendingKill.isEmpty)
    #expect(harness.store.state.layout.panes[id: paneID]?.tabs.map(\.id) == [harness.tabID])
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test(.dependencies) func contentRequestedCloseTabsToTheRightKeepsTheLeft() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .never }
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let third = await addTab(harness, title: "Three")
    let paneID = harness.paneID
    await harness.store.send(.contentRequestedClose(content: second.contentID, scope: .tabsToTheRight)) {
      $0.layout.panes[id: paneID]?.tabs.remove(id: third.tabID)
      $0.layout.panes[id: paneID]?.selectedTabID = second.tabID
    }
    await harness.store.receive(.runtime(.killConfirmed(id: third.contentID)))
    #expect(harness.store.state.layout.panes[id: paneID]?.tabs.map(\.id) == [harness.tabID, second.tabID])
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test(.dependencies) func contentRequestedCloseAllTabsCollapsesThePane() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .never }
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    // Close All drops every tab of the pane and collapses it.
    await harness.store.send(.contentRequestedClose(content: second.contentID, scope: .allTabs)) {
      $0.layout.tree = SplitTree()
      $0.layout.panes = []
      $0.layout.focusedPaneID = nil
    }
    // The merged reaps confirm in no guaranteed order.
    harness.store.exhaustivity = .off
    await harness.store.finish()
    #expect(harness.runtime.pendingKill.isEmpty)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test(.dependencies) func contentRequestedCloseAllTabsLeavesSiblingPanesAlone() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .never }
    let harness = await makeHarness()
    let sibling = await splitPane(harness, anchor: harness.paneID)
    // Close All is pane-scoped: the split partner keeps its tabs. Off
    // exhaustivity: the collapse diff (tree, focus retarget) is pinned by the
    // single-pane test above.
    harness.store.exhaustivity = .off
    await harness.store.send(.contentRequestedClose(content: harness.contentID, scope: .allTabs))
    await harness.store.finish()
    #expect(harness.store.state.layout.panes[id: harness.paneID] == nil)
    #expect(harness.store.state.layout.panes[id: sibling.paneID]?.tabs.isEmpty == false)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test(.dependencies) func contentRequestedCloseOtherTabsRaisesThePluralAlert() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .always }
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let third = await addTab(harness, title: "Three")
    // Literal copy pinned on purpose: the helper elsewhere mirrors the
    // production switch, which would hide a swapped branch.
    await harness.store.send(.contentRequestedClose(content: harness.contentID, scope: .otherTabs)) {
      $0.alertPaneID = harness.paneID
      $0.alert = AlertState {
        TextState("Close 2 Tabs?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmClose(tabs: [second.tabID, third.tabID])) {
          TextState("Close")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState("Closing will end these tabs' sessions.")
      }
    }
  }

  @Test(.dependencies) func contentRequestedCloseForUnknownContentIsANoOp() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .always }
    let harness = await makeHarness()
    await harness.store.send(.contentRequestedClose(content: ContentID(), scope: .tab))
    #expect(harness.store.state.layout.isConsistent)
  }

  // MARK: - Content-originated requests.

  @Test func contentRequestedNewTabInheritsFromTheSource() async throws {
    let harness = await makeHarness()
    let paneID = harness.paneID
    await harness.store.send(.contentRequestedNewTab(content: harness.contentID)) {
      $0.layout.panes[id: paneID]?.tabs.append(
        TabItem(
          id: TabID(rawValue: UUID(0)),
          title: "Terminal 1",
          content: ContentSnapshot(
            id: ContentID(rawValue: UUID(1)),
            state: .terminal(TerminalContentState(workingDirectory: nil))
          )
        )
      )
      $0.layout.panes[id: paneID]?.selectedTabID = TabID(rawValue: UUID(0))
    }
    let request = try #require(harness.recorder.requests.last)
    #expect(request.inheritedFrom == harness.contentID)
    #expect(request.origin == .tab)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func contentRequestedSplitOpensAFreshTabInTheNewPane() async throws {
    let harness = await makeHarness()
    await harness.store.send(.contentRequestedSplit(content: harness.contentID, direction: .right)) {
      let newPaneID = PaneID(rawValue: UUID(2))
      $0.layout.tree = try $0.layout.tree.inserting(view: newPaneID, at: harness.paneID, direction: .right)
      $0.layout.panes.append(
        Pane(
          id: newPaneID,
          tabs: [
            TabItem(
              id: TabID(rawValue: UUID(0)),
              title: "Terminal 1",
              content: ContentSnapshot(
                id: ContentID(rawValue: UUID(1)),
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: TabID(rawValue: UUID(0))
        )
      )
      $0.layout.focusedPaneID = newPaneID
    }
    let request = try #require(harness.recorder.requests.last)
    #expect(request.inheritedFrom == harness.contentID)
    #expect(request.origin == .split)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func contentRequestedFocusFollowsTheContentsPane() async throws {
    let harness = await makeHarness()
    _ = await splitPane(harness, anchor: harness.paneID)
    // Focus followed the split; the source content's input focus pulls it back.
    await harness.store.send(.contentRequestedFocus(content: harness.contentID)) {
      $0.layout.focusedPaneID = harness.paneID
    }
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func contentRequestedResizeGrowsThePaneByPixels() async throws {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    // Give both visible renderers real extents so the tree has a size.
    harness.mock?.renderer?.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    harness.recorder.contents[split.contentID]?.renderer?.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    // 100px rightward over a 1600px-wide horizontal split: 0.5 + 100/1600.
    await harness.store.send(
      .contentRequestedResize(content: harness.contentID, direction: .right, amount: 100)
    ) {
      let node = try #require($0.layout.tree.root)
      $0.layout.tree = try $0.layout.tree.resizing(
        node: try #require($0.layout.tree.find(id: harness.paneID.rawValue)),
        by: 100,
        in: .right,
        with: CGRect(origin: .zero, size: node.viewBounds { _ in CGSize(width: 800, height: 600) })
      )
    }
    let ratio: Double? =
      switch harness.store.state.layout.tree.root {
      case .split(let split): split.ratio
      case .leaf, nil: nil
      }
    #expect(ratio == 0.5625)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func contentRequestedResizeWithoutAMatchingAxisIsANoOp() async {
    let harness = await makeHarness()
    harness.mock?.renderer?.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    // A lone pane has no split to resize.
    await harness.store.send(.contentRequestedResize(content: harness.contentID, direction: .right, amount: 50))
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func contentRequestedResizeWithDegenerateBoundsIsANoOp() async {
    let harness = await makeHarness()
    _ = await splitPane(harness, anchor: harness.paneID)
    // Renderers report zero extents (mid-wake); the ratio must not move.
    await harness.store.send(.contentRequestedResize(content: harness.contentID, direction: .right, amount: 50))
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func contentRequestedFocusSplitMovesToTheNeighbor() async throws {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    await harness.store.send(.contentRequestedFocusSplit(content: split.contentID, direction: .previous)) {
      $0.layout.focusedPaneID = harness.paneID
    }
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func contentRequestedGotoTabWrapsAroundTheStrip() async {
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let paneID = harness.paneID
    // Selection sits on the second tab; next wraps to the first.
    await harness.store.send(.contentRequestedGotoTab(content: second.contentID, target: .next)) {
      $0.layout.panes[id: paneID]?.selectedTabID = harness.tabID
    }
    await harness.store.send(.contentRequestedGotoTab(content: harness.contentID, target: .previous)) {
      $0.layout.panes[id: paneID]?.selectedTabID = second.tabID
    }
    await harness.store.send(.contentRequestedGotoTab(content: second.contentID, target: .position(1))) {
      $0.layout.panes[id: paneID]?.selectedTabID = harness.tabID
    }
    // A one-based position beyond the strip clamps to the last tab.
    await harness.store.send(.contentRequestedGotoTab(content: harness.contentID, target: .position(9))) {
      $0.layout.panes[id: paneID]?.selectedTabID = second.tabID
    }
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func contentRequestedMoveTabReordersOnlyTheSelectedTab() async {
    let harness = await makeHarness()
    let second = await addTab(harness, title: "Two")
    let paneID = harness.paneID
    // The first tab is not selected; its keybind must not shuffle the strip.
    await harness.store.send(.contentRequestedMoveTab(content: harness.contentID, amount: 1))
    // The selected second tab wraps from the tail to the front.
    await harness.store.send(.contentRequestedMoveTab(content: second.contentID, amount: 1)) {
      $0.layout.panes[id: paneID]?.tabs = [
        Self.tab(id: second.tabID, contentID: second.contentID, title: "Two"),
        Self.tab(id: harness.tabID, contentID: harness.contentID, title: "One"),
      ]
    }
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func renameAndTitleCommitsRespectTheTitleLock() async {
    let harness = await makeHarness()
    let paneID = harness.paneID
    // Lock the bootstrap tab's title, as a script tab would be.
    await harness.store.send(.renameTab(id: harness.tabID, title: "Custom")) {
      $0.layout.panes[id: paneID]?.tabs[id: harness.tabID]?.customTitle = "Custom"
    }
    var locked = harness.store.state.layout
    locked.panes[id: paneID]?.tabs[id: harness.tabID]?.isLocked = true
    let bundle = makeStore(layout: locked)
    await bundle.store.send(.renameTab(id: harness.tabID, title: "Rejected"))
    await bundle.store.send(.runtime(.titleCommitted(id: harness.contentID, title: "Shell Report")))
    #expect(bundle.store.state.layout.panes[id: paneID]?.tabs[id: harness.tabID]?.customTitle == "Custom")
    #expect(bundle.store.state.layout.panes[id: paneID]?.tabs[id: harness.tabID]?.title == "One")
  }

  @Test func contentRequestedToggleZoomZoomsTheContentsPane() async {
    let harness = await makeHarness()
    _ = await splitPane(harness, anchor: harness.paneID)
    await harness.store.send(.contentRequestedToggleZoom(content: harness.contentID)) {
      $0.layout.focusedPaneID = harness.paneID
      $0.layout.tree = $0.layout.tree.settingZoomed($0.layout.tree.find(id: harness.paneID.rawValue))
    }
    #expect(harness.store.state.layout.isConsistent)
  }
}
