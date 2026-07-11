import Foundation
import GhosttyKit
import Testing

@testable import supacode

@MainActor
struct WorktreeSurfaceStateDropTests {
  private struct SplitTab {
    let state: WorktreeSurfaceState
    let tabId: TerminalTabID
    let paneA: GhosttySurfaceView
    let paneB: GhosttySurfaceView
  }

  /// Dropping a pane onto a sibling rearranges the tree by id (content-agnostic
  /// resolution through `visibleLeaves`, not the terminal-only `surfaces` map)
  /// and focuses the moved pane.
  @Test func dropRearrangesTreeAndFocusesPayload() {
    let tab = makeSplitTab()

    // Initial `.newSplit(.right)` puts B to the right of A.
    #expect(tab.state.splitTree(for: tab.tabId).root?.leftmostLeaf().id == tab.paneA.id)

    // Drop B onto A's left → B becomes the leftmost pane.
    tab.state.performSplitOperation(
      .drop(payloadId: tab.paneB.id, destinationId: tab.paneA.id, zone: .left), in: tab.tabId)

    let leaves = tab.state.splitTree(for: tab.tabId).visibleLeaves()
    #expect(leaves.count == 2)
    #expect(tab.state.splitTree(for: tab.tabId).root?.leftmostLeaf().id == tab.paneB.id)
    #expect(tab.state.focusedSurfaceIDForTesting(in: tab.tabId) == tab.paneB.id)
  }

  @Test func dropOntoSelfIsNoOp() {
    let tab = makeSplitTab()
    let before = tab.state.splitTree(for: tab.tabId).root?.leftmostLeaf().id

    tab.state.performSplitOperation(
      .drop(payloadId: tab.paneA.id, destinationId: tab.paneA.id, zone: .left), in: tab.tabId)

    #expect(tab.state.splitTree(for: tab.tabId).root?.leftmostLeaf().id == before)
    #expect(tab.state.splitTree(for: tab.tabId).visibleLeaves().count == 2)
  }

  @Test func dropWithUnknownPayloadIsNoOp() {
    let tab = makeSplitTab()
    let before = tab.state.splitTree(for: tab.tabId).root?.leftmostLeaf().id

    tab.state.performSplitOperation(
      .drop(payloadId: UUID(), destinationId: tab.paneA.id, zone: .left), in: tab.tabId)

    #expect(tab.state.splitTree(for: tab.tabId).root?.leftmostLeaf().id == before)
    #expect(tab.state.splitTree(for: tab.tabId).visibleLeaves().count == 2)
  }

  // MARK: - Helpers

  /// A worktree state with one tab split into two terminal panes (A left, B right).
  private func makeSplitTab() -> SplitTab {
    let manager = WorktreeSurfaceManager(runtime: GhosttyRuntime())
    let state = manager.state(for: makeWorktree())
    state.ensureInitialTab(focusing: true)

    guard let tabId = state.tabManager.selectedTabId,
      let paneA = state.splitTree(for: tabId).root?.leftmostLeaf().terminalForTesting
    else {
      fatalError("Expected an initial tab with one terminal pane")
    }

    _ = state.performSplitAction(.newSplit(direction: .right), for: paneA.id)

    guard
      let paneB = state.splitTree(for: tabId).visibleLeaves()
        .first(where: { $0.id != paneA.id })?.terminalForTesting
    else {
      fatalError("Expected a second pane after the split")
    }

    return SplitTab(state: state, tabId: tabId, paneA: paneA, paneB: paneB)
  }

  private func makeWorktree(id: String = "/tmp/repo/wt-1") -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
  }
}
