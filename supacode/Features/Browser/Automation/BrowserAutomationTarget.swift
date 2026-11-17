import Foundation
import IdentifiedCollections

nonisolated struct BrowserAutomationTarget: Equatable, Sendable {
  enum Resolution: Equatable, Sendable {
    case tab(BrowserAutomationTarget)
    case refused(String)
  }

  static let openHint = "Open one with `supacode browser open <url>`."

  var worktreeID: Worktree.ID
  var tabID: TabID
  var contentID: ContentID

  static func resolve(
    tabID: String?,
    worktreeID: Worktree.ID?,
    layouts: [(worktreeID: Worktree.ID, layout: PaneLayout)],
    liveTitle: (ContentID) -> String? = { _ in nil }
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
    let browserTabs = layout.panes.flatMap(\.tabs).filter { $0.content.kind == .browser }
    let focusedTab = layout.focusedPaneID.flatMap { layout.panes[id: $0]?.selectedTab }
    let chosen = browserTabs.count == 1 ? browserTabs.first : browserTabs.first { $0.id == focusedTab?.id }
    if let chosen {
      return .tab(BrowserAutomationTarget(worktreeID: worktreeID, tabID: chosen.id, contentID: chosen.content.id))
    }
    guard !browserTabs.isEmpty else {
      return .refused("No browser tab in this worktree. \(openHint)")
    }
    let listed = browserTabs.prefix(8).map { tab in
      "\(tab.id.rawValue.uuidString)  \(tab.customTitle ?? liveTitle(tab.content.id) ?? tab.title)"
    }
    return .refused("Several browser tabs are open. Pass -t <tab>:\n" + listed.joined(separator: "\n"))
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
