import Foundation
import IdentifiedCollections

nonisolated struct BrowserAutomationTarget: Equatable, Sendable {
  enum Resolution: Equatable, Sendable {
    case tab(BrowserAutomationTarget)
    case ambiguous([Candidate])
    case refused(String)
  }

  struct Candidate: Equatable, Sendable {
    var tabID: TabID
    var contentID: ContentID
    var customTitle: String?
    var storedTitle: String
    var storedURL: URL?
  }

  static let listLimit = 20

  static func candidates(in layout: PaneLayout) -> [Candidate] {
    layout.panes.flatMap(\.tabs).compactMap { tab in
      guard case .browser(let state) = tab.content.state else { return nil }
      return Candidate(
        tabID: tab.id,
        contentID: tab.content.id,
        customTitle: tab.customTitle,
        storedTitle: tab.title,
        storedURL: state.url
      )
    }
  }

  static let openHint = "Open one with `supacode browser open <url>`."

  var worktreeID: Worktree.ID
  var tabID: TabID
  var contentID: ContentID

  static func resolve(
    tabID: String?,
    worktreeID: Worktree.ID?,
    layouts: [(worktreeID: Worktree.ID, layout: PaneLayout)]
  ) -> Resolution {
    if let tabID {
      return resolve(explicit: tabID, layouts: layouts)
    }
    guard let worktreeID else {
      return .refused("No worktree is focused. Pass -t <tab>.")
    }
    guard let layout = layouts.first(where: { $0.worktreeID == worktreeID })?.layout else {
      return .refused("No browser tab in this worktree. \(openHint)")
    }
    let browserTabs = candidates(in: layout)
    let focusedTab = layout.focusedPaneID.flatMap { layout.panes[id: $0]?.selectedTab }
    let chosen = browserTabs.count == 1 ? browserTabs.first : browserTabs.first { $0.tabID == focusedTab?.id }
    if let chosen {
      return .tab(BrowserAutomationTarget(worktreeID: worktreeID, tabID: chosen.tabID, contentID: chosen.contentID))
    }
    guard !browserTabs.isEmpty else {
      return .refused("No browser tab in this worktree. \(openHint)")
    }
    return .ambiguous(Array(browserTabs.prefix(listLimit)))
  }

  private static func resolve(
    explicit tabID: String,
    layouts: [(worktreeID: Worktree.ID, layout: PaneLayout)]
  ) -> Resolution {
    guard let uuid = UUID(uuidString: tabID) else {
      return .refused("`\(tabID)` is not a tab ID.")
    }
    for (worktreeID, layout) in layouts {
      for tab in layout.panes.flatMap(\.tabs) where tab.id.rawValue == uuid || tab.content.id.rawValue == uuid {
        guard tab.content.kind == .browser else {
          return .refused("Tab \(tabID) is not a browser tab.")
        }
        return .tab(BrowserAutomationTarget(worktreeID: worktreeID, tabID: tab.id, contentID: tab.content.id))
      }
    }
    return .refused("No tab \(tabID). \(openHint)")
  }
}
