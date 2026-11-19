import Foundation
import IdentifiedCollections

nonisolated enum BrowserTabPlacement: Equatable, Sendable {
  case tab(near: ContentID)
  case beside

  nonisolated enum Resolved: Equatable, Sendable {
    case tab(PaneID)
    case splitRight(PaneID)
  }

  func resolve(
    in layout: PaneLayout,
    windowedPaneIDs: Set<PaneID>,
    hasRoomForSplit: (PaneID) -> Bool
  ) -> Resolved? {
    guard let focused = layout.focusedPaneID ?? layout.panes.first?.id else { return nil }
    switch self {
    case .tab(let contentID):
      return .tab(layout.tab(containingContent: contentID)?.pane.id ?? focused)
    case .beside:
      return Self.resolveBeside(
        focused: focused,
        in: layout,
        windowedPaneIDs: windowedPaneIDs,
        hasRoomForSplit: hasRoomForSplit
      )
    }
  }

  private static func resolveBeside(
    focused: PaneID,
    in layout: PaneLayout,
    windowedPaneIDs: Set<PaneID>,
    hasRoomForSplit: (PaneID) -> Bool
  ) -> Resolved {
    if showsBrowser(focused, in: layout) || windowedPaneIDs.contains(focused) {
      return .tab(focused)
    }
    if case .leaf(let zoomed) = layout.tree.zoomed {
      return .tab(zoomed)
    }
    let candidates = layout.tree.visibleLeaves().filter { $0 != focused && !windowedPaneIDs.contains($0) }
    if let browserPane = candidates.first(where: { showsBrowser($0, in: layout) }) {
      return .tab(browserPane)
    }
    if let node = layout.tree.find(id: focused.rawValue),
      let neighbor = layout.tree.focusTarget(for: .spatial(.right), from: node),
      neighbor != focused, candidates.contains(neighbor)
    {
      return .tab(neighbor)
    }
    return hasRoomForSplit(focused) ? .splitRight(focused) : .tab(focused)
  }

  private static func showsBrowser(_ paneID: PaneID, in layout: PaneLayout) -> Bool {
    layout.panes[id: paneID]?.selectedTab?.content.kind == .browser
  }
}
