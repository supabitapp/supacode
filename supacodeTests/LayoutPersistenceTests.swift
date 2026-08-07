import AppKit
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct LayoutPersistenceTests {
  private final class StubContent: TabContent {
    let id: ContentID
    let kind: ContentKind = .terminal
    var snapshotState: TerminalContentState

    init(id: ContentID, snapshotState: TerminalContentState) {
      self.id = id
      self.snapshotState = snapshotState
    }

    var renderer: NSView? { nil }
    func startSession(at geometry: ContentGeometry) {}
    func hibernate() {}
    func snapshot() -> ContentSnapshot {
      ContentSnapshot(id: id, state: .terminal(snapshotState))
    }
  }

  private func layout(paneID: PaneID, tabID: TerminalTabID, contentID: ContentID) -> PaneLayout {
    PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: tabID,
              title: "One",
              content: ContentSnapshot(
                id: contentID,
                state: .terminal(TerminalContentState(workingDirectory: "/stored"))
              )
            )
          ],
          selectedTabID: tabID
        )
      ],
      focusedPaneID: paneID
    )
  }

  @Test func overlaysLiveSnapshotsOverStoredOnes() throws {
    let paneID = PaneID()
    let tabID = TerminalTabID()
    let contentID = ContentID()
    let runtime = ContentRuntime()
    let grid = try #require(
      FrozenGrid.from(backingSize: CGSize(width: 1024, height: 768), columns: 80, rows: 24, scale: 2, fontSize: 13)
    )
    let live = StubContent(
      id: contentID,
      snapshotState: TerminalContentState(workingDirectory: "/live", frozenGrid: grid)
    )
    _ = runtime.provision(live, at: .fallback)

    let record = LayoutPersistence.record(
      for: layout(paneID: paneID, tabID: tabID, contentID: contentID),
      runtime: runtime
    )
    let saved = record.layout.panes[id: paneID]?.tabs[id: tabID]?.content.state
    guard case .terminal(let state) = saved else {
      Issue.record("Expected a terminal payload.")
      return
    }
    // The last applied grid wins over the stored one, so a quit-time save can
    // never persist a stale grid.
    #expect(state.workingDirectory == "/live")
    #expect(state.frozenGrid == grid)
  }

  @Test func keepsStoredSnapshotWhenContentIsHibernated() {
    let paneID = PaneID()
    let tabID = TerminalTabID()
    let contentID = ContentID()
    let runtime = ContentRuntime()

    // No live content registered: the stored snapshot must survive verbatim.
    let record = LayoutPersistence.record(
      for: layout(paneID: paneID, tabID: tabID, contentID: contentID),
      runtime: runtime
    )
    let saved = record.layout.panes[id: paneID]?.tabs[id: tabID]?.content.state
    guard case .terminal(let state) = saved else {
      Issue.record("Expected a terminal payload.")
      return
    }
    #expect(state.workingDirectory == "/stored")
  }
}
