import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct LayoutFeatureBrowserTests {
  @MainActor
  private final class StubContent: TabContent {
    let id: ContentID
    let kind: ContentKind
    private let state: ContentState
    private var view: NSView?

    init(request: ContentRequest) {
      id = request.contentID
      kind = request.content.kind
      state = request.content
    }

    nonisolated deinit {}

    var renderer: NSView? { view }

    func startSession(at geometry: ContentGeometry) {
      view = NSView()
    }

    func hibernate() {
      view = nil
    }

    func snapshot() -> ContentSnapshot {
      ContentSnapshot(id: id, state: state)
    }
  }

  private static let worktreeID = WorktreeID("/tmp/layout-feature-browser")

  private func makeStore(
    paneID: PaneID,
    killed: LockIsolated<[ContentID]>
  ) -> (store: TestStoreOf<LayoutFeature>, runtime: ContentRuntime) {
    let runtime = ContentRuntime()
    let store = TestStore(
      initialState: LayoutFeature.State(
        id: Self.worktreeID,
        layout: PaneLayout(tree: SplitTree(view: paneID), panes: [Pane(id: paneID)], focusedPaneID: paneID)
      )
    ) {
      LayoutFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.contentRuntime = runtime
      $0.layoutContentFactory = LayoutContentFactory(make: { StubContent(request: $0) })
      $0[ContentSessionKiller.self] = ContentSessionKiller(
        kill: { contentID, _ in killed.withValue { $0.append(contentID) } }
      )
    }
    store.exhaustivity = .off
    return (store, runtime)
  }

  private static func terminalSpec(tabID: TabID, contentID: ContentID) -> NewTabSpec {
    NewTabSpec(
      tabID: tabID,
      contentID: contentID,
      title: "Terminal",
      content: .terminal(TerminalContentState(workingDirectory: nil)),
      geometry: .fallback
    )
  }

  private static func browserSpec(tabID: TabID, contentID: ContentID, url: URL?) -> NewTabSpec {
    NewTabSpec(
      tabID: tabID,
      contentID: contentID,
      title: "New Tab",
      content: .browser(BrowserContentState(url: url)),
      geometry: .fallback
    )
  }

  @Test func theBrowserSpecSeedsABrowserTabForThePage() {
    let url = URL(string: "http://localhost:3000")
    let spec = NewTabSpec.browser(url: url, geometry: .fallback, select: false)
    #expect(spec.title == "New Tab")
    #expect(spec.content == .browser(BrowserContentState(url: url)))
    #expect(!spec.select)
  }

  @Test(.dependencies) func aBrowserTabLandsInThePaneWithItsPage() async {
    let paneID = PaneID()
    let killed = LockIsolated<[ContentID]>([])
    let (store, runtime) = makeStore(paneID: paneID, killed: killed)
    let tabID = TabID()
    let contentID = ContentID()
    let url = URL(string: "http://localhost:3000")

    await store.send(.newTab(inPane: paneID, spec: Self.browserSpec(tabID: tabID, contentID: contentID, url: url)))

    let tab = store.state.layout.panes[id: paneID]?.tabs[id: tabID]
    #expect(tab?.title == "New Tab")
    #expect(tab?.content == ContentSnapshot(id: contentID, state: .browser(BrowserContentState(url: url))))
    #expect(store.state.layout.panes[id: paneID]?.selectedTabID == tabID)
    #expect(runtime.content(for: contentID)?.kind == .browser)
    #expect(runtime.renderer(for: contentID) != nil)
  }

  @Test(.dependencies) func closingABrowserTabKillsNoSessionAndLeavesNoTombstone() async {
    let paneID = PaneID()
    let killed = LockIsolated<[ContentID]>([])
    let (store, runtime) = makeStore(paneID: paneID, killed: killed)
    let terminalTab = TabID()
    let terminalContent = ContentID()
    let browserTab = TabID()
    let browserContent = ContentID()
    await store.send(
      .newTab(inPane: paneID, spec: Self.terminalSpec(tabID: terminalTab, contentID: terminalContent)))
    await store.send(
      .newTab(inPane: paneID, spec: Self.browserSpec(tabID: browserTab, contentID: browserContent, url: nil)))

    await store.send(.closeTab(id: browserTab))
    await store.finish()

    #expect(store.state.layout.panes[id: paneID]?.tabs.map(\.id) == [terminalTab])
    #expect(store.state.layout.panes[id: paneID]?.selectedTabID == terminalTab)
    #expect(runtime.content(for: browserContent) == nil)
    #expect(runtime.pendingKill.isEmpty)
    #expect(killed.value.isEmpty)
  }

  @Test(.dependencies) func closingATerminalTabStillKillsItsSession() async {
    let paneID = PaneID()
    let killed = LockIsolated<[ContentID]>([])
    let (store, runtime) = makeStore(paneID: paneID, killed: killed)
    let terminalTab = TabID()
    let terminalContent = ContentID()
    let browserTab = TabID()
    let browserContent = ContentID()
    await store.send(
      .newTab(inPane: paneID, spec: Self.browserSpec(tabID: browserTab, contentID: browserContent, url: nil)))
    await store.send(
      .newTab(inPane: paneID, spec: Self.terminalSpec(tabID: terminalTab, contentID: terminalContent)))

    await store.send(.closeTab(id: terminalTab))
    await store.finish()

    #expect(killed.value == [terminalContent])
    #expect(runtime.pendingKill.isEmpty)
    #expect(store.state.layout.panes[id: paneID]?.tabs.map(\.id) == [browserTab])
  }

  @Test(.dependencies) func closingAPaneOfMixedTabsKillsOnlyTheTerminalSessions() async {
    let paneID = PaneID()
    let killed = LockIsolated<[ContentID]>([])
    let (store, _) = makeStore(paneID: paneID, killed: killed)
    let terminalContent = ContentID()
    let browserContent = ContentID()
    await store.send(.newTab(inPane: paneID, spec: Self.terminalSpec(tabID: TabID(), contentID: terminalContent)))
    await store.send(
      .newTab(inPane: paneID, spec: Self.browserSpec(tabID: TabID(), contentID: browserContent, url: nil)))

    await store.send(.closePane(id: paneID))
    await store.finish()

    #expect(store.state.layout.panes.isEmpty)
    #expect(killed.value == [terminalContent])
  }

  @Test(.dependencies) func aNewTabRequestedFromABrowserOpensABlankBrowserTab() async {
    let paneID = PaneID()
    let killed = LockIsolated<[ContentID]>([])
    let (store, _) = makeStore(paneID: paneID, killed: killed)
    let browserTab = TabID()
    let browserContent = ContentID()
    let url = URL(string: "https://example.com")
    await store.send(
      .newTab(inPane: paneID, spec: Self.browserSpec(tabID: browserTab, contentID: browserContent, url: url)))

    await store.send(.contentRequestedNewTab(content: browserContent))

    let tabs = store.state.layout.panes[id: paneID]?.tabs ?? []
    #expect(tabs.count == 2)
    #expect(tabs.last?.content.state == .browser(BrowserContentState()))
    #expect(store.state.layout.panes[id: paneID]?.selectedTabID == tabs.last?.id)
  }

  @Test(.dependencies) func splittingFromABrowserOpensABlankBrowserPane() async {
    let paneID = PaneID()
    let killed = LockIsolated<[ContentID]>([])
    let (store, _) = makeStore(paneID: paneID, killed: killed)
    let browserContent = ContentID()
    await store.send(
      .newTab(
        inPane: paneID,
        spec: Self.browserSpec(tabID: TabID(), contentID: browserContent, url: URL(string: "https://example.com"))))

    await store.send(.contentRequestedSplit(content: browserContent, direction: .right))

    #expect(store.state.layout.panes.count == 2)
    let newPane = store.state.layout.panes.first { $0.id != paneID }
    #expect(newPane?.selectedTab?.content.state == .browser(BrowserContentState()))
    #expect(store.state.layout.focusedPaneID == newPane?.id)
  }
}
