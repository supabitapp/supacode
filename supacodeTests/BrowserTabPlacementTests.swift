import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

struct BrowserTabPlacementTests {
  private static func tab(_ kind: ContentKind, contentID: ContentID = ContentID()) -> TabItem {
    let state: ContentState =
      switch kind {
      case .terminal: .terminal(TerminalContentState(workingDirectory: nil))
      case .browser: .browser(BrowserContentState())
      }
    return TabItem(id: TabID(), title: "Tab", content: ContentSnapshot(id: contentID, state: state))
  }

  private static func pane(_ id: PaneID, _ kind: ContentKind, contentID: ContentID = ContentID()) -> Pane {
    Pane(id: id, tabs: [tab(kind, contentID: contentID)])
  }

  private static func sideBySide(
    left: Pane,
    right: Pane,
    focused: PaneID
  ) throws -> PaneLayout {
    let tree = try SplitTree(view: left.id).inserting(view: right.id, at: left.id, direction: .right)
    return PaneLayout(tree: tree, panes: [left, right], focusedPaneID: focused)
  }

  private static func single(_ pane: Pane) -> PaneLayout {
    PaneLayout(tree: SplitTree(view: pane.id), panes: [pane], focusedPaneID: pane.id)
  }

  @Test func besideSplitsALoneTerminalPaneWhenThereIsRoom() {
    let paneID = PaneID()
    let layout = Self.single(Self.pane(paneID, .terminal))
    let resolved = BrowserTabPlacement.beside.resolve(
      in: layout, windowedPaneIDs: [], hasRoomForSplit: { _ in true })
    #expect(resolved == .splitRight(paneID))
  }

  @Test func besideOpensATabWhenTheLonePaneIsTooNarrowToSplit() {
    let paneID = PaneID()
    let layout = Self.single(Self.pane(paneID, .terminal))
    let resolved = BrowserTabPlacement.beside.resolve(
      in: layout, windowedPaneIDs: [], hasRoomForSplit: { _ in false })
    #expect(resolved == .tab(paneID))
  }

  @Test func besideReusesThePaneAlreadyShowingABrowser() throws {
    let left = PaneID()
    let right = PaneID()
    let layout = try Self.sideBySide(
      left: Self.pane(left, .browser), right: Self.pane(right, .terminal), focused: right)
    let resolved = BrowserTabPlacement.beside.resolve(
      in: layout, windowedPaneIDs: [], hasRoomForSplit: { _ in true })
    #expect(resolved == .tab(left))
  }

  @Test func besideReusesTheRightNeighborOfAFocusedTerminal() throws {
    let left = PaneID()
    let right = PaneID()
    let layout = try Self.sideBySide(
      left: Self.pane(left, .terminal), right: Self.pane(right, .terminal), focused: left)
    let resolved = BrowserTabPlacement.beside.resolve(
      in: layout, windowedPaneIDs: [], hasRoomForSplit: { _ in true })
    #expect(resolved == .tab(right))
  }

  @Test func besideSplitsTheRightmostFocusedTerminal() throws {
    let left = PaneID()
    let right = PaneID()
    let layout = try Self.sideBySide(
      left: Self.pane(left, .terminal), right: Self.pane(right, .terminal), focused: right)
    let resolved = BrowserTabPlacement.beside.resolve(
      in: layout, windowedPaneIDs: [], hasRoomForSplit: { _ in true })
    #expect(resolved == .splitRight(right))
  }

  @Test func besideStaysInAFocusedBrowserPane() throws {
    let left = PaneID()
    let right = PaneID()
    let layout = try Self.sideBySide(
      left: Self.pane(left, .terminal), right: Self.pane(right, .browser), focused: right)
    let resolved = BrowserTabPlacement.beside.resolve(
      in: layout, windowedPaneIDs: [], hasRoomForSplit: { _ in true })
    #expect(resolved == .tab(right))
  }

  @Test func besideNeverSplitsOrTargetsAWindowedPane() throws {
    let left = PaneID()
    let right = PaneID()
    let layout = try Self.sideBySide(
      left: Self.pane(left, .terminal), right: Self.pane(right, .browser), focused: left)
    let focusedIsWindowed = BrowserTabPlacement.beside.resolve(
      in: layout, windowedPaneIDs: [left], hasRoomForSplit: { _ in true })
    #expect(focusedIsWindowed == .tab(left))
    let browserIsWindowed = BrowserTabPlacement.beside.resolve(
      in: layout, windowedPaneIDs: [right], hasRoomForSplit: { _ in true })
    #expect(browserIsWindowed == .splitRight(left))
  }

  @Test func besideKeepsAZoomedPaneZoomed() throws {
    let left = PaneID()
    let right = PaneID()
    var layout = try Self.sideBySide(
      left: Self.pane(left, .terminal), right: Self.pane(right, .terminal), focused: left)
    layout.tree = layout.tree.settingZoomed(layout.tree.find(id: left.rawValue))
    let resolved = BrowserTabPlacement.beside.resolve(
      in: layout, windowedPaneIDs: [], hasRoomForSplit: { _ in true })
    #expect(resolved == .tab(left))
  }

  @Test func tabNearAContentOpensInThatContentsPane() throws {
    let left = PaneID()
    let right = PaneID()
    let source = ContentID()
    let layout = try Self.sideBySide(
      left: Self.pane(left, .terminal),
      right: Self.pane(right, .browser, contentID: source),
      focused: left
    )
    let resolved = BrowserTabPlacement.tab(near: source).resolve(
      in: layout, windowedPaneIDs: [], hasRoomForSplit: { _ in true })
    #expect(resolved == .tab(right))
  }

  @Test func anEmptyLayoutHasNoPlacement() {
    let resolved = BrowserTabPlacement.beside.resolve(
      in: PaneLayout(), windowedPaneIDs: [], hasRoomForSplit: { _ in true })
    #expect(resolved == nil)
  }
}
