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

  private func layout(paneID: PaneID, tabID: TabID, contentID: ContentID) -> PaneLayout {
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
    let tabID = TabID()
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

  @Test func stripsBlockingScriptTabsAndRetargetsSelectionLeft() {
    let paneID = PaneID()
    let keptTab = TabID()
    let scriptTab = TabID()
    let keptContent = ContentID()
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: keptTab,
              title: "Shell",
              content: ContentSnapshot(
                id: keptContent,
                state: .terminal(TerminalContentState(workingDirectory: "/kept"))
              )
            ),
            TabItem(
              id: scriptTab,
              title: "Setup",
              content: ContentSnapshot(
                id: ContentID(),
                state: .terminal(
                  TerminalContentState(
                    workingDirectory: nil,
                    launch: LaunchOverride(command: "./setup.sh", bypassZmx: true)
                  )
                )
              ),
              isTitleLocked: true
            ),
          ],
          selectedTabID: scriptTab
        )
      ],
      focusedPaneID: paneID
    )
    let record = LayoutPersistence.record(for: layout, runtime: ContentRuntime())
    let pane = record.layout.panes[id: paneID]
    #expect(pane?.tabs.map(\.id) == [keptTab])
    #expect(pane?.selectedTabID == keptTab)
    #expect(record.layout.isConsistent)
  }

  @Test func stripsAPaneEmptiedByItsBlockingScriptTab() {
    let keptPaneID = PaneID()
    let scriptPaneID = PaneID()
    let keptTab = TabID()
    let scriptTab = TabID()
    var tree = SplitTree<PaneID>(view: keptPaneID)
    tree = (try? tree.inserting(view: scriptPaneID, at: keptPaneID, direction: .right)) ?? tree
    let layout = PaneLayout(
      tree: tree,
      panes: [
        Pane(
          id: keptPaneID,
          tabs: [
            TabItem(
              id: keptTab,
              title: "Shell",
              content: ContentSnapshot(
                id: ContentID(),
                state: .terminal(TerminalContentState(workingDirectory: "/kept"))
              )
            )
          ],
          selectedTabID: keptTab
        ),
        Pane(
          id: scriptPaneID,
          tabs: [
            TabItem(
              id: scriptTab,
              title: "Setup",
              content: ContentSnapshot(
                id: ContentID(),
                state: .terminal(
                  TerminalContentState(
                    workingDirectory: nil,
                    launch: LaunchOverride(command: "./setup.sh", bypassZmx: true)
                  )
                )
              )
            )
          ],
          selectedTabID: scriptTab
        ),
      ],
      focusedPaneID: scriptPaneID
    )
    let record = LayoutPersistence.record(for: layout, runtime: ContentRuntime())
    #expect(record.layout.panes.map(\.id) == [keptPaneID])
    #expect(record.layout.tree.leaves() == [keptPaneID])
    #expect(record.layout.focusedPaneID == keptPaneID)
    #expect(record.layout.isConsistent)
  }

  @Test func launchOverridesNeverReachTheWire() throws {
    // A non-blocking command tab persists, but its command must not replay on
    // restore: the encoder drops the launch payload entirely.
    let state = TerminalContentState(
      workingDirectory: "/w",
      launch: LaunchOverride(command: "echo hi", initialInput: "input")
    )
    let data = try JSONEncoder().encode(state)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("echo hi"))
    let decoded = try JSONDecoder().decode(TerminalContentState.self, from: data)
    #expect(decoded.launch == nil)
    #expect(decoded.workingDirectory == "/w")
  }

  @Test func keepsStoredSnapshotWhenContentIsHibernated() {
    let paneID = PaneID()
    let tabID = TabID()
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
