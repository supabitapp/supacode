import AppKit
import Sharing
import SupacodeSettingsShared
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

  @Test func insertingADuplicateLeafThrows() throws {
    let tree = try SplitTree(view: IDLeaf(id: 1))
      .inserting(view: IDLeaf(id: 2), at: IDLeaf(id: 1), direction: .right)
    #expect(throws: SplitTree<IDLeaf>.SplitError.duplicateLeaf) {
      try tree.inserting(view: IDLeaf(id: 2), at: IDLeaf(id: 1), direction: .down)
    }
  }

  @Test func codableRoundTripsLeafOnlyTree() throws {
    let tree = SplitTree(view: IDLeaf(id: 1))

    let data = try JSONEncoder().encode(tree)
    let decoded = try JSONDecoder().decode(SplitTree<IDLeaf>.self, from: data)

    #expect(decoded == tree)
  }

  @Test func codableRoundTripsNestedSplitsWithRatios() throws {
    let tree = try SplitTree(view: IDLeaf(id: 1))
      .inserting(view: IDLeaf(id: 2), at: IDLeaf(id: 1), direction: .right, ratio: 0.25)
      .inserting(view: IDLeaf(id: 3), at: IDLeaf(id: 2), direction: .down, ratio: 0.75)

    let data = try JSONEncoder().encode(tree)
    let decoded = try JSONDecoder().decode(SplitTree<IDLeaf>.self, from: data)

    #expect(decoded == tree)
  }

  @Test func parentSplitInfoReportsAxisAndSide() throws {
    let leafA = IDLeaf(id: 1)
    let leafB = IDLeaf(id: 2)
    let tree = try SplitTree(view: leafA).inserting(view: leafB, at: leafA, direction: .right)
    #expect(tree.parentSplitInfo(ofLeaf: leafA)?.axis == .horizontal)
    #expect(tree.parentSplitInfo(ofLeaf: leafA)?.isLeadingChild == true)
    #expect(tree.parentSplitInfo(ofLeaf: leafB)?.isLeadingChild == false)
    // The root leaf shares no divider.
    #expect(SplitTree(view: leafA).parentSplitInfo(ofLeaf: leafA) == nil)
  }

  @Test func insertingSpanningParentWrapsTheImmediateParentSplit() throws {
    let leafA = IDLeaf(id: 1)
    let leafB = IDLeaf(id: 2)
    let leafC = IDLeaf(id: 3)
    // A | B is a horizontal split; spanning C upward over A's divider must wrap
    // the whole H(A,B) in a vertical split: V(C, H(A,B)).
    let tree = try SplitTree(view: leafA).inserting(view: leafB, at: leafA, direction: .right)
    let spanned = try tree.insertingSpanningParent(view: leafC, ofLeaf: leafA, direction: .top)
    guard case .split(let outer) = spanned.root else {
      Issue.record("expected a spanning outer split, got \(String(describing: spanned.root))")
      return
    }
    #expect(outer.direction == .vertical)
    #expect(outer.left == .leaf(view: leafC))
    guard case .split(let inner) = outer.right else {
      Issue.record("expected the wrapped H(A,B) split")
      return
    }
    #expect(inner.direction == .horizontal)
    #expect(inner.left == .leaf(view: leafA))
    #expect(inner.right == .leaf(view: leafB))
  }

  @Test func codableRoundTripsZoomedNodePath() throws {
    let tree = try SplitTree(view: IDLeaf(id: 1))
      .inserting(view: IDLeaf(id: 2), at: IDLeaf(id: 1), direction: .right)
      .inserting(view: IDLeaf(id: 3), at: IDLeaf(id: 2), direction: .down)
    let zoomedNode = try #require(tree.find(id: 3))
    let zoomed = tree.settingZoomed(zoomedNode)

    let data = try JSONEncoder().encode(zoomed)
    let decoded = try JSONDecoder().decode(SplitTree<IDLeaf>.self, from: data)

    #expect(decoded == zoomed)
    #expect(decoded.zoomed == zoomedNode)
  }

  @Test func codableDropsZoomedPathThatNoLongerResolves() throws {
    let json = #"{"root":{"kind":"leaf","leaf":{"id":1}},"zoomedPath":["left","right"]}"#

    let decoded = try JSONDecoder().decode(SplitTree<IDLeaf>.self, from: Data(json.utf8))

    #expect(decoded.zoomed == nil)
    #expect(decoded.root == .leaf(view: IDLeaf(id: 1)))
  }

  @Test func codableWireFormatIsPinned() throws {
    let tree = try SplitTree(view: IDLeaf(id: 1))
      .inserting(view: IDLeaf(id: 2), at: IDLeaf(id: 1), direction: .right, ratio: 0.25)
    let zoomed = tree.settingZoomed(try #require(tree.find(id: 1)))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = try #require(String(bytes: encoder.encode(zoomed), encoding: .utf8))

    let expected =
      #"{"root":{"direction":"horizontal","kind":"split","left":{"kind":"leaf","leaf":{"id":1}},"#
      + #""ratio":0.25,"right":{"kind":"leaf","leaf":{"id":2}}},"zoomedPath":["left"]}"#
    #expect(json == expected)
  }

}

private final class SplitTreeTestView: NSView, Identifiable {
  let id = UUID()
}

nonisolated private struct IDLeaf: Identifiable, Hashable, Codable {
  let id: Int
}
