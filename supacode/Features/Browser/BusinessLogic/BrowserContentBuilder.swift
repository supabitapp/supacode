import Foundation

struct BrowserContentBuilder {
  var host: (Worktree.ID) -> WorktreeContentHost?
  var openBrowserTab: (Worktree.ID, URL, ContentID) -> Void

  func browserContent(_ request: ContentRequest, browserState: BrowserContentState) -> any TabContent {
    let contentID = request.contentID
    let worktreeID = request.worktreeID
    let host = host
    let openBrowserTab = openBrowserTab
    return BrowserContent(
      id: contentID,
      initialState: browserState,
      callbacks: BrowserContentCallbacks(
        focused: {
          guard let host = host(worktreeID) else { return }
          host.sendLayoutAction(.contentRequestedFocus(content: contentID))
          host.recordActiveSurface(contentID.rawValue)
        },
        stateChanged: {
          host(worktreeID)?.onReportedTitleChanged?()
        },
        openInNewTab: { url in
          openBrowserTab(worktreeID, url, contentID)
        },
        closeRequested: {
          host(worktreeID)?.sendLayoutAction(.contentRequestedClose(content: contentID, scope: .tab))
        },
        shouldClaimFocus: {
          host(worktreeID)?.shouldClaimFocus(contentID.rawValue) ?? false
        },
        attached: {
          host(worktreeID)?.reassertSurfaceActivity()
        }
      )
    )
  }
}
