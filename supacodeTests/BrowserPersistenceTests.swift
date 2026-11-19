import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import SupacodeSettingsFeature
@testable import supacode

@MainActor
struct BrowserPersistenceTests {
  private static func browserTab(url: URL?) -> TabItem {
    TabItem(
      id: TabID(),
      title: "Docs",
      content: ContentSnapshot(id: ContentID(), state: .browser(BrowserContentState(url: url)))
    )
  }

  private static func terminalTab() -> TabItem {
    TabItem(
      id: TabID(),
      title: "Terminal",
      content: ContentSnapshot(id: ContentID(), state: .terminal(TerminalContentState(workingDirectory: "/tmp")))
    )
  }

  @Test func aLayoutWithBrowserTabsRoundTrips() throws {
    let paneA = PaneID()
    let paneB = PaneID()
    let page = Self.browserTab(url: URL(string: "http://localhost:3000/app?tab=1"))
    let blank = Self.browserTab(url: nil)
    let terminal = Self.terminalTab()
    let layout = PaneLayout(
      tree: try SplitTree(view: paneA).inserting(view: paneB, at: paneA, direction: .right),
      panes: [
        Pane(id: paneA, tabs: [terminal], selectedTabID: terminal.id),
        Pane(id: paneB, tabs: [page, blank], selectedTabID: page.id),
      ],
      focusedPaneID: paneA
    )

    let decoded = try JSONDecoder().decode(PaneLayout.self, from: JSONEncoder().encode(layout))

    #expect(decoded == layout)
    #expect(decoded.isConsistent)
    #expect(decoded.panes[id: paneB]?.selectedTab?.content.kind == .browser)
  }

  @Test func theBrowserWireFormatIsPinned() throws {
    let state = ContentState.browser(BrowserContentState(url: URL(string: "https://example.com/docs")))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let json = String(bytes: try encoder.encode(state), encoding: .utf8)
    #expect(json == #"{"browser":{"url":"https://example.com/docs"},"kind":"browser"}"#)
  }

  @Test func aBlankBrowserTabDecodesWithoutAURL() throws {
    let data = Data(#"{"browser":{},"kind":"browser"}"#.utf8)
    #expect(try JSONDecoder().decode(ContentState.self, from: data) == .browser(BrowserContentState()))
  }

  @Test func browserTabsSurviveThePersistedLayoutStripping() {
    let paneID = PaneID()
    let page = Self.browserTab(url: URL(string: "https://example.com"))
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [Pane(id: paneID, tabs: [page], selectedTabID: page.id)],
      focusedPaneID: paneID
    )
    #expect(layout.strippingEphemeralContent() == layout)
  }

  @Test func aBrowserTabPresentsAsAPageAndATerminalTabAsATerminal() {
    #expect(ContentKind.browser.tabIcon == "globe")
    #expect(!ContentKind.browser.dimsWhenUnfocused)
    #expect(ContentKind.browser.unavailableMessage == "This page is unavailable.")
    #expect(ContentKind.terminal.tabIcon == nil)
    #expect(ContentKind.terminal.dimsWhenUnfocused)
    #expect(ContentKind.terminal.unavailableMessage == "This terminal is unavailable.")
  }

  @Test func aFreshSeedOfABrowserIsABlankBrowser() {
    let state = ContentState.browser(BrowserContentState(url: URL(string: "https://example.com")))
    #expect(state.freshSeed == .browser(BrowserContentState()))
    #expect(!state.isEphemeral)
  }

  @Test func settingsWithoutTheLinkRoutingKeyDecodeWithItOff() throws {
    let data = try JSONEncoder().encode(GlobalSettings.default)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object.removeValue(forKey: "opensLinksInBrowserTab") != nil)
    let decoded = try JSONDecoder().decode(
      GlobalSettings.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(!decoded.opensLinksInBrowserTab)
  }

  @Test func linkRoutingRoundTripsThroughSettings() throws {
    var settings = GlobalSettings.default
    settings.opensLinksInBrowserTab = true
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.opensLinksInBrowserTab)
  }

  @Test(.dependencies) func togglingLinkRoutingPersistsChanges() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = .default }

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }

    await store.send(.binding(.set(\.opensLinksInBrowserTab, true))) {
      $0.opensLinksInBrowserTab = true
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(settingsFile.global.opensLinksInBrowserTab)
  }
}
