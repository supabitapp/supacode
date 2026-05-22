import Foundation
import Testing

@testable import supacode

struct BranchMenuNodeTests {
  @Test func splitsNestedBranchesIntoSubmenus() {
    let nodes = BranchMenuNode.build(
      branches: ["sbertix/feature", "sbertix/fix", "main"],
      refPrefix: ""
    )

    #expect(nodes.map(\.name) == ["main", "sbertix"])

    let main = nodes[0]
    #expect(main.children.isEmpty)
    #expect(main.ref == "main")

    let sbertix = nodes[1]
    #expect(sbertix.ref == nil)
    #expect(sbertix.children.map(\.name) == ["feature", "fix"])
    #expect(sbertix.children.map(\.ref) == ["sbertix/feature", "sbertix/fix"])
  }

  @Test func appliesRemoteRefPrefix() {
    let nodes = BranchMenuNode.build(branches: ["sbertix/x"], refPrefix: "origin/")

    let group = nodes[0]
    #expect(group.name == "sbertix")
    #expect(group.id == "origin/sbertix")
    #expect(group.children[0].name == "x")
    #expect(group.children[0].ref == "origin/sbertix/x")
  }

  @Test func deeplyNestsMultipleSegments() {
    let nodes = BranchMenuNode.build(branches: ["a/b/c"], refPrefix: "")

    #expect(nodes[0].name == "a")
    #expect(nodes[0].ref == nil)
    #expect(nodes[0].children[0].name == "b")
    #expect(nodes[0].children[0].children[0].name == "c")
    #expect(nodes[0].children[0].children[0].ref == "a/b/c")
  }

  @Test func flatBranchProducesSingleLeaf() {
    let nodes = BranchMenuNode.build(branches: ["main"], refPrefix: "")

    #expect(nodes.count == 1)
    #expect(nodes[0].children.isEmpty)
    #expect(nodes[0].ref == "main")
  }

  @Test func nodeThatIsBothABranchAndANamespaceStaysSelectable() {
    // `feature` is a branch AND the parent of `feature/x`: the node must keep a
    // non-nil ref while also carrying children.
    let nodes = BranchMenuNode.build(branches: ["feature", "feature/x"], refPrefix: "")

    #expect(nodes.count == 1)
    let feature = nodes[0]
    #expect(feature.name == "feature")
    #expect(feature.ref == "feature")
    #expect(feature.children.map(\.name) == ["x"])
    #expect(feature.children[0].ref == "feature/x")
  }
}
