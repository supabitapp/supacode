import Testing

@testable import supacode

@MainActor
struct SidebarGroupNestingTests {
  private let rowA: SidebarItemID = "/tmp/repo/a"
  private let rowB: SidebarItemID = "/tmp/repo/b"
  private let rowC: SidebarItemID = "/tmp/repo/c"
  private let rowD: SidebarItemID = "/tmp/repo/d"
  private let rowE: SidebarItemID = "/tmp/repo/e"

  @Test func normalizedTrimsComponentsAndDropsEmptyOnes() {
    #expect(SidebarGroupNesting.normalized(" Project 1 // Backend / ") == "Project 1/Backend")
    #expect(SidebarGroupNesting.normalized("Project 1") == "Project 1")
    #expect(SidebarGroupNesting.normalized("  ") == nil)
    #expect(SidebarGroupNesting.normalized(" / ") == nil)
  }

  @Test func pathsIncludeEveryAncestor() {
    #expect(SidebarGroupNesting.paths(including: "a/b/c") == ["a", "a/b", "a/b/c"])
    #expect(SidebarGroupNesting.paths(including: "a") == ["a"])
  }

  @Test func ungroupedRowsStayFlatInIncomingOrder() {
    let rows = SidebarGroupNesting.buildRows(orderedIDs: [rowC, rowA, rowB], groupByID: [:], collapsedPaths: [])

    #expect(
      rows == [
        .leaf(id: rowC, depth: 0, displayName: nil),
        .leaf(id: rowA, depth: 0, displayName: nil),
        .leaf(id: rowB, depth: 0, displayName: nil),
      ])
  }

  @Test func foldersAppearAtTheirFirstRowAndKeepRowOrder() {
    let rows = SidebarGroupNesting.buildRows(
      orderedIDs: [rowA, rowB, rowC, rowD, rowE],
      groupByID: [rowB: "P1", rowC: "P2", rowD: "P1/Sub", rowE: "P1"],
      collapsedPaths: []
    )

    #expect(
      rows == [
        .leaf(id: rowA, depth: 0, displayName: nil),
        .groupHeader(
          prefix: "P1", components: ["P1"], depth: 0, isCollapsed: false, leafDescendantIDs: [rowB, rowD, rowE]),
        .leaf(id: rowB, depth: 1, displayName: nil),
        .groupHeader(prefix: "P1/Sub", components: ["Sub"], depth: 1, isCollapsed: false, leafDescendantIDs: [rowD]),
        .leaf(id: rowD, depth: 2, displayName: nil),
        .leaf(id: rowE, depth: 1, displayName: nil),
        .groupHeader(prefix: "P2", components: ["P2"], depth: 0, isCollapsed: false, leafDescendantIDs: [rowC]),
        .leaf(id: rowC, depth: 1, displayName: nil),
      ])
  }

  @Test func collapsedFolderHidesItsRowsButListsThemOnTheHeader() {
    let rows = SidebarGroupNesting.buildRows(
      orderedIDs: [rowA, rowB, rowD],
      groupByID: [rowB: "P1", rowD: "P1/Sub"],
      collapsedPaths: ["P1"]
    )

    #expect(
      rows == [
        .leaf(id: rowA, depth: 0, displayName: nil),
        .groupHeader(prefix: "P1", components: ["P1"], depth: 0, isCollapsed: true, leafDescendantIDs: [rowB, rowD]),
      ])
  }
}
