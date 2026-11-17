import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

struct BrowserAutomationTargetTests {
  private static let worktreeID = WorktreeID("/tmp/repo")

  private static func tab(_ kind: ContentKind, title: String = "Tab") -> TabItem {
    let state: ContentState =
      switch kind {
      case .terminal: .terminal(TerminalContentState(workingDirectory: nil))
      case .browser: .browser(BrowserContentState())
      }
    return TabItem(id: TabID(), title: title, content: ContentSnapshot(id: ContentID(), state: state))
  }

  private static func layout(_ tabs: [TabItem], selected: TabItem? = nil) -> PaneLayout {
    let pane = Pane(id: PaneID(), tabs: .init(uniqueElements: tabs), selectedTabID: (selected ?? tabs.first)?.id)
    return PaneLayout(tree: SplitTree(view: pane.id), panes: [pane], focusedPaneID: pane.id)
  }

  private static func resolve(
    tabID: String? = nil,
    worktreeID: WorktreeID? = worktreeID,
    _ layout: PaneLayout
  ) -> BrowserAutomationTarget.Resolution {
    BrowserAutomationTarget.resolve(
      tabID: tabID, worktreeID: worktreeID, layouts: [(worktreeID: Self.worktreeID, layout: layout)])
  }

  private static func target(_ tab: TabItem) -> BrowserAutomationTarget.Resolution {
    .tab(BrowserAutomationTarget(worktreeID: worktreeID, tabID: tab.id, contentID: tab.content.id))
  }

  @Test func anExplicitTabIsFoundInAnyWorktreeByTabOrContentID() {
    let browser = Self.tab(.browser)
    let layout = Self.layout([Self.tab(.terminal), browser])
    #expect(Self.resolve(tabID: browser.id.rawValue.uuidString, worktreeID: nil, layout) == Self.target(browser))
    #expect(Self.resolve(tabID: browser.content.id.rawValue.uuidString, layout) == Self.target(browser))
  }

  @Test func anExplicitTabMustBeAKnownBrowserTab() {
    let terminal = Self.tab(.terminal)
    let layout = Self.layout([terminal])
    let terminalID = terminal.id.rawValue.uuidString
    #expect(Self.resolve(tabID: terminalID, layout) == .refused("Tab \(terminalID) is not a browser tab."))
    #expect(Self.resolve(tabID: "nope", layout) == .refused("`nope` is not a tab ID."))
    let unknown = UUID().uuidString
    #expect(
      Self.resolve(tabID: unknown, layout)
        == .refused("No tab \(unknown). Open one with `supacode browser open <url>`."))
  }

  @Test func theOnlyBrowserTabIsTheDefaultEvenWhenATerminalHasFocus() {
    let terminal = Self.tab(.terminal)
    let browser = Self.tab(.browser)
    #expect(Self.resolve(Self.layout([terminal, browser], selected: terminal)) == Self.target(browser))
  }

  @Test func severalBrowserTabsDefaultToTheFocusedOne() {
    let first = Self.tab(.browser, title: "Docs")
    let second = Self.tab(.browser, title: "App")
    #expect(Self.resolve(Self.layout([first, second], selected: second)) == Self.target(second))
  }

  @Test func severalBrowserTabsBehindATerminalAreListed() {
    let terminal = Self.tab(.terminal)
    let first = Self.tab(.browser, title: "Docs")
    let second = Self.tab(.browser, title: "App")
    let expected = """
      Several browser tabs are open. Pass -t <tab>:
      \(first.id.rawValue.uuidString)  Docs
      \(second.id.rawValue.uuidString)  App
      """
    #expect(Self.resolve(Self.layout([terminal, first, second], selected: terminal)) == .refused(expected))
  }

  @Test func listedTabsPreferARenameThenTheLivePageTitle() {
    let terminal = Self.tab(.terminal)
    var renamed = Self.tab(.browser, title: "New Tab")
    renamed.customTitle = "Docs"
    let live = Self.tab(.browser, title: "New Tab")
    let resolution = BrowserAutomationTarget.resolve(
      tabID: nil,
      worktreeID: Self.worktreeID,
      layouts: [(worktreeID: Self.worktreeID, layout: Self.layout([terminal, renamed, live], selected: terminal))],
      liveTitle: { _ in "Sign In" }
    )
    let expected = """
      Several browser tabs are open. Pass -t <tab>:
      \(renamed.id.rawValue.uuidString)  Docs
      \(live.id.rawValue.uuidString)  Sign In
      """
    #expect(resolution == .refused(expected))
  }

  @Test func aWorktreeWithoutABrowserTabSaysHowToOpenOne() {
    let refusal = BrowserAutomationTarget.Resolution.refused(
      "No browser tab in this worktree. Open one with `supacode browser open <url>`.")
    #expect(Self.resolve(Self.layout([Self.tab(.terminal)])) == refusal)
    #expect(Self.resolve(worktreeID: WorktreeID("/tmp/other"), Self.layout([Self.tab(.browser)])) == refusal)
    #expect(
      Self.resolve(worktreeID: nil, Self.layout([Self.tab(.browser)]))
        == .refused("No worktree is focused. Pass -t <tab>."))
  }
}
