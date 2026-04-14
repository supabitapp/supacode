import AppKit
import Testing

@testable import supacode

@MainActor
struct SplitTreeTests {
  @Test func focusTargetAfterClosingUsesNextForLeftmostLeaf() throws {
    let first = SplitTreeTestView()
    let second = SplitTreeTestView()
    let third = SplitTreeTestView()

    let tree = try SplitTree(view: first)
      .inserting(view: second, at: first, direction: .right)
      .inserting(view: third, at: second, direction: .right)

    let node = try #require(tree.find(id: first.id))
    #expect(tree.focusTargetAfterClosing(node) === second)
  }

  @Test func focusTargetAfterClosingUsesPreviousForNonLeftmostLeaf() throws {
    let first = SplitTreeTestView()
    let second = SplitTreeTestView()
    let third = SplitTreeTestView()

    let tree = try SplitTree(view: first)
      .inserting(view: second, at: first, direction: .right)
      .inserting(view: third, at: second, direction: .right)

    let node = try #require(tree.find(id: third.id))
    #expect(tree.focusTargetAfterClosing(node) === second)
  }

  @Test func focusTargetNextWrapsAroundFromZoomedNode() throws {
    let first = SplitTreeTestView()
    let second = SplitTreeTestView()
    let third = SplitTreeTestView()

    let tree = try SplitTree(view: first)
      .inserting(view: second, at: first, direction: .right)
      .inserting(view: third, at: second, direction: .right)

    let zoomedNode = tree.find(id: second.id)!
    let zoomed = tree.settingZoomed(zoomedNode)

    let next = zoomed.focusTarget(for: .next, from: zoomedNode)
    #expect(next === third)

    let nextNode = zoomed.find(id: third.id)!
    let rezoomed = zoomed.settingZoomed(nextNode)
    #expect(rezoomed.visibleLeaves().count == 1)
    #expect(rezoomed.visibleLeaves().first === third)
  }

  @Test func visibleLeavesOnlyReturnZoomedPane() throws {
    let first = SplitTreeTestView()
    let second = SplitTreeTestView()

    let tree = try SplitTree(view: first)
      .inserting(view: second, at: first, direction: .right)

    let zoomed = tree.settingZoomed(tree.find(id: second.id)!)
    let visibleLeaves = zoomed.visibleLeaves()

    #expect(visibleLeaves.count == 1)
    #expect(visibleLeaves.first === second)
  }

  @Test func gotoSplitPreservesZoomWhenConfigured() throws {
    let fixture = makeWorktreeFixture(preserveZoomOnNavigation: true)
    let first = fixture.first
    let second = try #require(fixture.second)

    #expect(fixture.state.performSplitAction(.toggleSplitZoom, for: first.id))
    #expect(fixture.state.performSplitAction(.gotoSplit(direction: .next), for: first.id))

    let visibleLeaves = fixture.state.splitTree(for: fixture.tabId).visibleLeaves()
    #expect(visibleLeaves.count == 1)
    #expect(visibleLeaves.first === second)
  }

  @Test func gotoSplitClearsZoomWhenNotConfigured() throws {
    let fixture = makeWorktreeFixture(preserveZoomOnNavigation: false)
    let first = fixture.first

    #expect(fixture.state.performSplitAction(.toggleSplitZoom, for: first.id))
    #expect(fixture.state.performSplitAction(.gotoSplit(direction: .next), for: first.id))

    let visibleLeaves = fixture.state.splitTree(for: fixture.tabId).visibleLeaves()
    #expect(visibleLeaves.count == 2)
  }

  private func makeWorktreeFixture(preserveZoomOnNavigation: Bool) -> WorktreeFixture {
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      splitPreserveZoomOnNavigation: { preserveZoomOnNavigation }
    )
    let tabId = state.createTab()!
    let first = state.splitTree(for: tabId).root!.leftmostLeaf()
    _ = state.performSplitAction(.newSplit(direction: .right), for: first.id)
    let leaves = state.splitTree(for: tabId).leaves()
    return WorktreeFixture(
      state: state,
      tabId: tabId,
      first: first,
      second: leaves.first { $0.id != first.id }
    )
  }

  private func makeWorktree() -> Worktree {
    Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }
}

private struct WorktreeFixture {
  let state: WorktreeTerminalState
  let tabId: TerminalTabID
  let first: GhosttySurfaceView
  let second: GhosttySurfaceView?
}

private final class SplitTreeTestView: NSView, Identifiable {
  let id = UUID()
}
