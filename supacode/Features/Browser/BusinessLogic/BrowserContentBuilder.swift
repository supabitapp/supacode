import AppKit

struct BrowserContentBuilder {
  var host: (Worktree.ID) -> WorktreeContentHost?
  var openBrowserTab: (Worktree.ID, URL, ContentID) -> Void

  func browserContent(_ request: ContentRequest, browserState: BrowserContentState) -> any TabContent {
    let contentID = request.contentID
    let worktreeID = request.worktreeID
    let openBrowserTab = openBrowserTab
    let host = host(worktreeID)
    return BrowserContent(
      id: contentID,
      initialState: browserState,
      callbacks: BrowserContentCallbacks(
        focused: { [weak host] in
          host?.sendLayoutAction(.contentRequestedFocus(content: contentID))
          host?.recordActiveSurface(contentID.rawValue)
        },
        stateChanged: { [weak host] in
          host?.onReportedTitleChanged?()
        },
        openInNewTab: { url in
          openBrowserTab(worktreeID, url, contentID)
        },
        closeRequested: { [weak host] in
          host?.sendLayoutAction(.contentRequestedClose(content: contentID, scope: .tab))
        },
        mayClaimFocus: { [weak host] window in
          host?.mayClaimFocus(contentID.rawValue, in: window) ?? false
        },
        attached: { [weak host] in
          host?.reassertSurfaceActivity()
        }
      )
    )
  }
}
