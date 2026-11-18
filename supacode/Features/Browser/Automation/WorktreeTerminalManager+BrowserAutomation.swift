import ComposableArchitecture
import Foundation

extension WorktreeTerminalManager {
  func runBrowserAutomation(
    _ request: BrowserAutomationRequest,
    worktreeID rawWorktreeID: String?,
    isCallerGone: @escaping () -> Bool = { false }
  ) async -> BrowserAutomationResult {
    let worktreeID =
      rawWorktreeID.map { WorktreeID($0.removingPercentEncoding ?? $0) }
      ?? appStore?.withState { $0.repositories.selectedWorktreeID }
    let content: BrowserContent
    var createdTabID: String?
    if let newTab = request.newTab {
      guard let opened = openAutomationTab(newTab, in: worktreeID) else {
        return BrowserAutomationResult(refusal: "Could not open a browser tab. Pass -w <worktree>.")
      }
      content = opened.content
      createdTabID = opened.tabID.rawValue.uuidString
    } else {
      let layouts = appStore?.withState { $0.terminals.layouts.map { (worktreeID: $0.id, layout: $0.layout) } } ?? []
      switch BrowserAutomationTarget.resolve(tabID: request.tabID, worktreeID: worktreeID, layouts: layouts) {
      case .refused(let message):
        return BrowserAutomationResult(refusal: message)
      case .ambiguous(let candidates):
        return BrowserAutomationResult(
          lines: candidates.map(Self.listing),
          refusal: "Several browser tabs are open. Pass -t <tab> with an ID from the page output."
        )
      case .tab(let target):
        guard let live = liveBrowserContent(target) else {
          return BrowserAutomationResult(refusal: "The browser tab could not be started.")
        }
        content = live
      }
    }
    var result = await content.automation.serialized {
      if request.newTab?.url != nil {
        _ = await content.waitUntilLoaded(timeout: BrowserAutomationRunner.loadTimeout)
      }
      return await BrowserAutomationRunner(page: content, reportsChanges: !request.quiet, isCallerGone: isCallerGone)
        .run(request.steps)
    }
    result.createdTabID = createdTabID
    return result
  }

  private static func listing(_ candidate: BrowserAutomationTarget.Candidate) -> String {
    let content = ContentRuntime.liveValue.content(for: candidate.contentID) as? BrowserContent
    let title = candidate.customTitle ?? content?.page.reportedTitle ?? candidate.storedTitle
    return "\(candidate.tabID.rawValue.uuidString)  \(content?.automation.redacted(title) ?? title)"
  }

  private func openAutomationTab(
    _ newTab: BrowserAutomationRequest.NewTab,
    in worktreeID: Worktree.ID?
  ) -> (tabID: TabID, content: BrowserContent)? {
    guard let worktree = appStore?.withState({ $0.repositories.worktree(for: worktreeID) }) else { return nil }
    _ = host(for: worktree)
    let tabID = TabID()
    let contentID = ContentID()
    openBrowserTab(
      in: worktree.id,
      url: newTab.url.flatMap(BrowserAddress.resolve),
      placement: .beside,
      focusing: newTab.background != true,
      tabID: tabID,
      contentID: contentID
    )
    guard let content = ContentRuntime.liveValue.content(for: contentID) as? BrowserContent else { return nil }
    return (tabID, content)
  }

  private func liveBrowserContent(_ target: BrowserAutomationTarget) -> BrowserContent? {
    if ContentRuntime.liveValue.renderer(for: target.contentID) == nil {
      sendLayout(target.worktreeID, .wakeTab(id: target.tabID))
    }
    guard let content = ContentRuntime.liveValue.content(for: target.contentID) as? BrowserContent,
      content.renderer != nil
    else { return nil }
    return content
  }
}
