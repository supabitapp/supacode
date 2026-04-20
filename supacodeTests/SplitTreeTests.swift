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

  // Locks in that both the AppKit responder path (clicks -> onFocusChange)
  // and the explicit focus path (goto_split / focusSurface) route through
  // the same choke point and produce one focus-changed emission per real
  // transition.
  @Test func recordActiveSurfaceSymmetryAcrossClickAndGotoSplitPaths() throws {
    let fixture = makeWorktreeFixture(preserveZoomOnNavigation: false)
    let first = fixture.first
    let second = try #require(fixture.second)
    let state = fixture.state
    let tabId = fixture.tabId

    var emissions: [UUID] = []
    state.onFocusChanged = { emissions.append($0) }

    // Creating the split already focused `second`, but `onFocusChanged`
    // wasn't wired yet; establish the baseline.
    #expect(state.activeSurfaceID(for: tabId) == second.id)

    // Simulates the AppKit responder path (a user clicking a pane).
    first.onFocusChange?(true)
    #expect(state.activeSurfaceID(for: tabId) == first.id)

    // Same surface reported twice should dedup.
    first.onFocusChange?(true)
    #expect(state.activeSurfaceID(for: tabId) == first.id)

    // Simulates the explicit focus path (keybinding / palette / goto_split).
    #expect(state.performSplitAction(.gotoSplit(direction: .next), for: first.id))
    #expect(state.activeSurfaceID(for: tabId) == second.id)

    // Explicit-path idempotence: re-focusing the already-active surface
    // must not re-emit.
    #expect(state.focusSurface(id: second.id))
    #expect(state.activeSurfaceID(for: tabId) == second.id)

    // Focus loss (e.g. window resign) must not wipe the active pane or emit
    // a stray focus-changed event — the overlay needs to remember the last
    // active surface across window key transitions.
    second.onFocusChange?(false)
    #expect(state.activeSurfaceID(for: tabId) == second.id)

    #expect(emissions == [first.id, second.id])
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
