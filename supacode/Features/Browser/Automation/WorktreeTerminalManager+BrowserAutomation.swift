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
    switch request.operation {
    case .open(let url, let background):
      return await openAutomationTab(url: url, background: background, in: worktreeID)
    case .listTabs:
      return listBrowserTabs(in: worktreeID)
    case .close:
      let resolution = resolve(request.tabID, in: worktreeID)
      guard case .tab(let target) = resolution else {
        return Self.refusal(resolution)
      }
      sendLayout(target.worktreeID, .closeTab(id: target.tabID))
      return BrowserAutomationResult(lines: ["closed \(target.tabID.rawValue.uuidString)"])
    case .run(let steps, let quiet):
      let resolution = resolve(request.tabID, in: worktreeID)
      guard case .tab(let target) = resolution else {
        return Self.refusal(resolution)
      }
      guard let content = liveBrowserContent(target) else {
        return BrowserAutomationResult(refusal: "The browser tab could not be started.")
      }
      return await content.automation.serialized {
        await BrowserAutomationRunner(page: content, reportsChanges: !quiet, isCallerGone: isCallerGone).run(steps)
      }
    }
  }

  private var browserLayouts: [(worktreeID: Worktree.ID, layout: PaneLayout)] {
    appStore?.withState { $0.terminals.layouts.map { (worktreeID: $0.id, layout: $0.layout) } } ?? []
  }

  private func resolve(_ tabID: String?, in worktreeID: Worktree.ID?) -> BrowserAutomationTarget.Resolution {
    BrowserAutomationTarget.resolve(tabID: tabID, worktreeID: worktreeID, layouts: browserLayouts)
  }

  private static func refusal(_ resolution: BrowserAutomationTarget.Resolution) -> BrowserAutomationResult {
    switch resolution {
    case .refused(let message):
      BrowserAutomationResult(refusal: message)
    case .ambiguous(let candidates):
      BrowserAutomationResult(
        lines: candidates.map(listing),
        refusal: "Several browser tabs are open. Pass -t <tab> with an ID from the page output."
      )
    case .tab:
      BrowserAutomationResult()
    }
  }

  private func listBrowserTabs(in worktreeID: Worktree.ID?) -> BrowserAutomationResult {
    guard let worktreeID else {
      return BrowserAutomationResult(refusal: "No worktree is focused. Pass -w <worktree>.")
    }
    let layout = browserLayouts.first { $0.worktreeID == worktreeID }?.layout
    let candidates = layout.map(BrowserAutomationTarget.candidates) ?? []
    guard !candidates.isEmpty else {
      return BrowserAutomationResult(lines: ["(no browser tabs)"])
    }
    return BrowserAutomationResult(lines: candidates.prefix(BrowserAutomationTarget.listLimit).map(Self.listing))
  }

  private static func listing(_ candidate: BrowserAutomationTarget.Candidate) -> String {
    let content = ContentRuntime.liveValue.content(for: candidate.contentID) as? BrowserContent
    let title = candidate.customTitle ?? content?.page.reportedTitle ?? candidate.storedTitle
    let url = (content?.page.url ?? candidate.storedURL)?.absoluteString ?? ""
    let line = "\(candidate.tabID.rawValue.uuidString)  \(title)  \(url)"
    return content?.automation.redacted(line) ?? line
  }

  private func openAutomationTab(
    url: URL?,
    background: Bool,
    in worktreeID: Worktree.ID?
  ) async -> BrowserAutomationResult {
    guard let worktree = appStore?.withState({ $0.repositories.worktree(for: worktreeID) }) else {
      return BrowserAutomationResult(refusal: "Could not open a browser tab. Pass -w <worktree>.")
    }
    _ = host(for: worktree)
    let tabID = TabID()
    let contentID = ContentID()
    openBrowserTab(
      in: worktree.id,
      url: url,
      placement: .beside,
      focusing: !background,
      tabID: tabID,
      contentID: contentID
    )
    guard let content = ContentRuntime.liveValue.content(for: contentID) as? BrowserContent else {
      return BrowserAutomationResult(refusal: "Could not open a browser tab. Pass -w <worktree>.")
    }
    content.captureConsole()
    if url != nil {
      await content.automation.serialized {
        _ = await content.waitUntilLoaded(timeout: BrowserAutomationRunner.loadTimeout)
      }
    }
    return BrowserAutomationResult(createdTabID: tabID.rawValue.uuidString)
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
