import Testing

@testable import supacode

/// Locks the title contract now that reported titles live on the content's
/// chrome instead of in `LayoutFeature`: nothing but the chrome carries a
/// terminal's live title, and the layout's own title is the fallback.
@MainActor
struct TabTitleTests {
  private func tab(
    title: String = "Terminal 1",
    customTitle: String? = nil,
    isLocked: Bool = false,
    contentID: ContentID = ContentID()
  ) -> TabItem {
    TabItem(
      id: TabID(),
      title: title,
      customTitle: customTitle,
      content: ContentSnapshot(
        id: contentID,
        state: .terminal(TerminalContentState(workingDirectory: nil))
      ),
      isLocked: isLocked
    )
  }

  private func chrome(reporting title: String?) -> TerminalTabChrome {
    let chrome = TerminalTabChrome()
    chrome.reportedTitle = title
    return chrome
  }

  @Test func theReportedTitleWinsOverTheLayoutsOwn() {
    #expect(TabTitle.resolved(for: tab(), chrome: chrome(reporting: "zsh")) == "zsh")
    #expect(TabTitle.stored(for: tab(), chrome: chrome(reporting: "zsh")) == "zsh")
  }

  @Test func anAbsentOrEmptyReportFallsBackToTheLayoutsTitle() {
    #expect(TabTitle.resolved(for: tab(), chrome: chrome(reporting: nil)) == "Terminal 1")
    #expect(TabTitle.resolved(for: tab(), chrome: chrome(reporting: "")) == "Terminal 1")
    #expect(TabTitle.resolved(for: tab(), chrome: nil) == "Terminal 1")
  }

  @Test func aUserOverrideWinsOverTheReportButNeverPersists() {
    let renamed = tab(customTitle: "Custom")
    #expect(TabTitle.resolved(for: renamed, chrome: chrome(reporting: "zsh")) == "Custom")
    // The override persists in its own field; folding it into the stored title
    // would make clearing the rename restore the override text.
    #expect(TabTitle.stored(for: renamed, chrome: chrome(reporting: "zsh")) == "zsh")
  }

  @Test func aLockedTabRefusesTheShellsReport() {
    let script = tab(title: "Setup", isLocked: true)
    #expect(TabTitle.resolved(for: script, chrome: chrome(reporting: "zsh")) == "Setup")
    #expect(TabTitle.stored(for: script, chrome: chrome(reporting: "zsh")) == "Setup")
  }

  @Test func resolvingThroughTheRuntimeReadsTheRegisteredContentsChrome() {
    let contentID = ContentID()
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: contentID)
    _ = runtime.provision(content, at: .fallback)
    content.terminalChrome.reportedTitle = "claude"
    #expect(TabTitle.resolved(for: tab(contentID: contentID), runtime: runtime) == "claude")
  }
}
