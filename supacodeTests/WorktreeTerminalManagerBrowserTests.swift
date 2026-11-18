import Clocks
import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsFeature
import SupacodeSettingsShared
import Testing
import WebKit

@testable import supacode

@MainActor
struct WorktreeTerminalManagerBrowserTests {
  private struct Harness {
    let manager: WorktreeTerminalManager
    let store: Store<AppFeature.State, AppFeature.Action>
    let worktree: Worktree

    var layout: PaneLayout? {
      store.withState { $0.terminals.layouts[id: worktree.id]?.layout }
    }

    var browserURLs: [URL?] {
      (layout?.panes ?? []).flatMap(\.tabs).compactMap { tab in
        guard case .browser(let state) = tab.content.state else { return nil }
        return .some(state.url)
      }
    }
  }

  private func makeHarness(opensLinksInBrowserTab: Bool = false, usesLiveBrowserContent: Bool = false) -> Harness {
    let worktree = Worktree(
      id: WorktreeID("/tmp/repo/wt-browser"),
      name: "wt-browser",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-browser"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let manager = withDependencies {
      $0.settingsFileStorage = .inMemory()
      $0.defaultAppStorage = .inMemory
      $0.zmxClient = .noop
    } operation: {
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global.opensLinksInBrowserTab = opensLinksInBrowserTab }
      return WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    let store = Store(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.contentRuntime = usesLiveBrowserContent ? ContentRuntime.liveValue : ContentRuntime()
      if usesLiveBrowserContent {
        $0.continuousClock = TestClock()
      }
      $0[LayoutContentFactory.self] = LayoutContentFactory { request in
        guard usesLiveBrowserContent, case .browser(let state) = request.content else {
          return InertTabContent(id: request.contentID, state: request.content)
        }
        return BrowserContent(
          id: request.contentID,
          initialState: state,
          callbacks: BrowserContentCallbacks(),
          makeWebView: {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            return BrowserWebView(frame: .zero, configuration: configuration)
          }
        )
      }
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    manager.appStore = store
    return Harness(manager: manager, store: store, worktree: worktree)
  }

  @Test(.dependencies) func openingABrowserTabBootstrapsAnEmptyLayout() {
    let harness = makeHarness()
    let url = URL(string: "http://localhost:3000")

    harness.manager.handleCommand(.openBrowserTab(harness.worktree, url: url, focusing: false))

    #expect(harness.layout?.panes.count == 1)
    #expect(harness.layout?.isConsistent == true)
    #expect(harness.browserURLs == [url])
  }

  @Test(.dependencies) func aSecondBrowserTabJoinsThePaneThatShowsABrowser() {
    let harness = makeHarness()
    let first = URL(string: "http://localhost:3000")
    let second = URL(string: "http://localhost:3000/next")

    harness.manager.handleCommand(.openBrowserTab(harness.worktree, url: first))
    harness.manager.handleCommand(.openBrowserTab(harness.worktree, url: second))

    #expect(harness.layout?.panes.count == 1)
    #expect(harness.browserURLs == [first, second])
    #expect(harness.layout?.panes.first?.selectedTab?.content.state == .browser(BrowserContentState(url: second)))
  }

  @Test func sessionTerminationTracksTerminalContentOnly() {
    let paneID = PaneID()
    let terminal = TabItem(
      id: TabID(),
      title: "Terminal",
      content: ContentSnapshot(id: ContentID(), state: .terminal(TerminalContentState(workingDirectory: nil)))
    )
    let browser = TabItem(
      id: TabID(),
      title: "Docs",
      content: ContentSnapshot(
        id: ContentID(), state: .browser(BrowserContentState(url: URL(string: "https://example.com"))))
    )
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [Pane(id: paneID, tabs: [terminal, browser], selectedTabID: browser.id)],
      focusedPaneID: paneID
    )
    let host = WorktreeContentHost(
      worktree: Worktree(
        id: WorktreeID("/tmp/repo/wt-sessions"),
        name: "wt-sessions",
        detail: "detail",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-sessions"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
      ),
      runtime: ContentRuntime(),
      clock: ContinuousClock(),
      runSetupScript: false
    )
    host.layout = { layout }

    #expect(host.sessionSurfaceIDs == [terminal.content.id.rawValue])
    #expect(Set(host.allSurfaceIDs) == [terminal.content.id.rawValue, browser.content.id.rawValue])
  }

  @Test(.dependencies) func aTerminalWebLinkOpensInABrowserTabWhenLinkRoutingIsOn() throws {
    let harness = makeHarness(opensLinksInBrowserTab: true)
    let host = harness.manager.host(for: harness.worktree)
    let url = try #require(URL(string: "http://localhost:8765/second.html"))

    #expect(host.onOpenLink?(url) == true)
    #expect(harness.browserURLs == [url])
  }

  @Test(.dependencies) func aTerminalWebLinkStaysWithTheSystemWhenLinkRoutingIsOff() throws {
    let harness = makeHarness(opensLinksInBrowserTab: false)
    let host = harness.manager.host(for: harness.worktree)
    let url = try #require(URL(string: "http://localhost:8765/second.html"))

    #expect(host.onOpenLink?(url) == false)
    #expect(harness.browserURLs.isEmpty)
  }

  @Test(.dependencies) func aTerminalFileLinkNeverOpensInABrowserTab() {
    let harness = makeHarness(opensLinksInBrowserTab: true)
    let host = harness.manager.host(for: harness.worktree)

    #expect(host.onOpenLink?(URL(fileURLWithPath: "/tmp/output.txt")) == false)
    #expect(harness.browserURLs.isEmpty)
  }

  @Test(.dependencies) func automationRefusesATabThatDoesNotExist() async {
    let harness = makeHarness()
    let unknown = UUID().uuidString
    let request = BrowserAutomationRequest(tabID: unknown, steps: [BrowserAutomationStep(verb: .snapshot)])

    let result = await harness.manager.runBrowserAutomation(request, worktreeID: nil)

    #expect(result.refusal == "No tab \(unknown). Open one with `supacode browser open <url>`.")
  }

  @Test(.dependencies) func automationDefaultsToTheWorktreesOnlyBrowserTab() async {
    let harness = makeHarness()
    harness.manager.handleCommand(
      .openBrowserTab(harness.worktree, url: URL(string: "http://localhost:3000"), focusing: false))
    let request = BrowserAutomationRequest(steps: [BrowserAutomationStep(verb: .snapshot)])

    let found = await harness.manager.runBrowserAutomation(request, worktreeID: "%2Ftmp%2Frepo%2Fwt-browser")
    let elsewhere = await harness.manager.runBrowserAutomation(request, worktreeID: "/tmp/repo/other")
    let unfocused = await harness.manager.runBrowserAutomation(request, worktreeID: nil)

    #expect(found.refusal == "The browser tab could not be started.")
    #expect(elsewhere.refusal == "No browser tab in this worktree. Open one with `supacode browser open <url>`.")
    #expect(unfocused.refusal == "No worktree is focused. Pass -t <tab>.")
  }

  @Test(.dependencies, .timeLimit(.minutes(1)))
  func automationWakesAHibernatedTabAndReadsItsPage() async throws {
    let harness = makeHarness(usesLiveBrowserContent: true)
    harness.manager.handleCommand(
      .openBrowserTab(
        harness.worktree,
        url: URL(string: "data:text/html,<title>Fixture</title><button>Go</button>"),
        focusing: false
      ))
    let tab = try #require(harness.layout?.panes.flatMap(\.tabs).first)
    defer { ContentRuntime.liveValue.remove(tab.content.id, tombstone: false) }
    let content = try #require(ContentRuntime.liveValue.content(for: tab.content.id) as? BrowserContent)
    content.hibernate()
    #expect(content.renderer == nil)
    let request = BrowserAutomationRequest(
      tabID: tab.id.rawValue.uuidString, steps: [BrowserAutomationStep(verb: .snapshot)])

    let result = await harness.manager.runBrowserAutomation(request, worktreeID: nil)

    #expect(result.refusal == nil)
    #expect(result.failure == nil)
    #expect(content.renderer != nil)
    #expect(result.lines.first?.hasPrefix("page: Fixture <data:text/html,") == true)
    #expect(result.lines.last?.hasPrefix("- button \"Go\" [ref=e") == true)
  }
}
