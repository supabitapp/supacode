import ComposableArchitecture
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct SidebarBranchNestingTests {
  // MARK: - SidebarBranchNesting.buildRows: structure.

  @Test func emptyInputReturnsEmpty() {
    let rows = SidebarBranchNesting.buildRows(itemIDs: [], branchNames: [:], collapsedPrefixes: [])
    #expect(rows.isEmpty)
  }

  @Test func singleLeafNoGrouping() {
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/main"],
      branchNames: ["/wt/main": "main"],
      collapsedPrefixes: []
    )
    #expect(rows == [.leaf(id: "/wt/main", depth: 0, displayName: nil)])
  }

  @Test func singleChildChainRendersAsFlatLeaf() {
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/main", "/wt/chore"],
      branchNames: ["/wt/main": "main", "/wt/chore": "chore/cleanup"],
      collapsedPrefixes: []
    )
    // No other branch shares the `chore` prefix, so the chain collapses and
    // the leaf renders flat with its full branch name. Sort is alphabetical.
    #expect(
      rows == [
        .leaf(id: "/wt/chore", depth: 0, displayName: nil),
        .leaf(id: "/wt/main", depth: 0, displayName: nil),
      ]
    )
  }

  @Test func twoLeavesSharedPrefix() {
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/a", "/wt/b"],
      branchNames: ["/wt/a": "feature/a", "/wt/b": "feature/b"],
      collapsedPrefixes: []
    )
    #expect(
      rows == [
        .groupHeader(
          prefix: "feature",
          components: ["feature"],
          depth: 0,
          isCollapsed: false,
          leafDescendantIDs: ["/wt/a", "/wt/b"]
        ),
        .leaf(id: "/wt/a", depth: 1, displayName: "a"),
        .leaf(id: "/wt/b", depth: 1, displayName: "b"),
      ]
    )
  }

  @Test func singleMultiComponentBranchStaysFlatWithoutHeader() {
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/x"],
      branchNames: ["/wt/x": "feature/tools/x"],
      collapsedPrefixes: []
    )
    // No branching anywhere along the chain, so no header is emitted.
    #expect(rows == [.leaf(id: "/wt/x", depth: 0, displayName: nil)])
  }

  @Test func deepNesting() {
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/a", "/wt/b", "/wt/c", "/wt/d"],
      branchNames: [
        "/wt/a": "feature/tools/a",
        "/wt/b": "feature/tools/b",
        "/wt/c": "feature/c",
        "/wt/d": "feature/d",
      ],
      collapsedPrefixes: []
    )
    // Alphabetical sort places `feature/c` and `feature/d` before
    // `feature/tools/...` because `c` < `d` < `tools` lexicographically.
    // The nested `tools` header sits inside the `feature` header, so its
    // `components` carries only the chain it added (just `tools`).
    #expect(
      rows == [
        .groupHeader(
          prefix: "feature",
          components: ["feature"],
          depth: 0,
          isCollapsed: false,
          leafDescendantIDs: ["/wt/c", "/wt/d", "/wt/a", "/wt/b"]
        ),
        .leaf(id: "/wt/c", depth: 1, displayName: "c"),
        .leaf(id: "/wt/d", depth: 1, displayName: "d"),
        .groupHeader(
          prefix: "feature/tools",
          components: ["tools"],
          depth: 1,
          isCollapsed: false,
          leafDescendantIDs: ["/wt/a", "/wt/b"]
        ),
        .leaf(id: "/wt/a", depth: 2, displayName: "a"),
        .leaf(id: "/wt/b", depth: 2, displayName: "b"),
      ]
    )
  }

  @Test func collapsedHeaderHidesLeaves() {
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/a", "/wt/b"],
      branchNames: ["/wt/a": "feature/a", "/wt/b": "feature/b"],
      collapsedPrefixes: ["feature"]
    )
    #expect(rows.count == 1)
    if case .groupHeader(_, _, _, let isCollapsed, let descendants) = rows[0] {
      #expect(isCollapsed)
      #expect(descendants == ["/wt/a", "/wt/b"])
    } else {
      Issue.record("Expected groupHeader, got \(rows[0])")
    }
  }

  @Test func innerHeaderCollapsedWhileOuterRemainsExpanded() {
    // Collapsing only `feature/tools` while leaving `feature` expanded
    // should hide `feature/tools`'s leaves but still render the outer
    // `feature` group's other children (`feature/c`).
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/a", "/wt/b", "/wt/c"],
      branchNames: [
        "/wt/a": "feature/tools/a",
        "/wt/b": "feature/tools/b",
        "/wt/c": "feature/c",
      ],
      collapsedPrefixes: ["feature/tools"]
    )
    #expect(
      rows == [
        .groupHeader(
          prefix: "feature",
          components: ["feature"],
          depth: 0,
          isCollapsed: false,
          leafDescendantIDs: ["/wt/c", "/wt/a", "/wt/b"]
        ),
        .leaf(id: "/wt/c", depth: 1, displayName: "c"),
        .groupHeader(
          prefix: "feature/tools",
          components: ["tools"],
          depth: 1,
          isCollapsed: true,
          leafDescendantIDs: ["/wt/a", "/wt/b"]
        ),
      ]
    )
  }

  @Test func collapsedDeepHeaderRollsUpAllDescendants() {
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/a", "/wt/b", "/wt/c"],
      branchNames: [
        "/wt/a": "feature/tools/a",
        "/wt/b": "feature/tools/b",
        "/wt/c": "feature/c",
      ],
      collapsedPrefixes: ["feature"]
    )
    #expect(rows.count == 1)
    if case .groupHeader(_, _, _, _, let descendants) = rows[0] {
      // Alphabetical walk: `feature/c` first, then `feature/tools/{a,b}`.
      #expect(descendants == ["/wt/c", "/wt/a", "/wt/b"])
    } else {
      Issue.record("Expected groupHeader, got \(rows[0])")
    }
  }

  // MARK: - SidebarBranchNesting.buildRows: edge cases for branch-name normalization.

  @Test func emptyBranchNameIsTopLevelLeaf() {
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/x"],
      branchNames: ["/wt/x": ""],
      collapsedPrefixes: []
    )
    #expect(rows == [.leaf(id: "/wt/x", depth: 0, displayName: nil)])
  }

  @Test func leadingSlashIsStripped() {
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/a", "/wt/b"],
      branchNames: ["/wt/a": "/feature/a", "/wt/b": "/feature/b"],
      collapsedPrefixes: []
    )
    #expect(rows.count == 3)
    if case .groupHeader(let prefix, _, _, _, _) = rows[0] {
      #expect(prefix == "feature")
    } else {
      Issue.record("Expected groupHeader as first row, got \(rows[0])")
    }
    #expect(rows[1] == .leaf(id: "/wt/a", depth: 1, displayName: "a"))
    #expect(rows[2] == .leaf(id: "/wt/b", depth: 1, displayName: "b"))
  }

  @Test func consecutiveSlashesCollapse() {
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/a", "/wt/b"],
      branchNames: ["/wt/a": "feature//a", "/wt/b": "feature//b"],
      collapsedPrefixes: []
    )
    #expect(rows.count == 3)
    if case .groupHeader(let prefix, _, _, _, _) = rows[0] {
      #expect(prefix == "feature")
    } else {
      Issue.record("Expected groupHeader as first row, got \(rows[0])")
    }
    #expect(rows[1] == .leaf(id: "/wt/a", depth: 1, displayName: "a"))
    #expect(rows[2] == .leaf(id: "/wt/b", depth: 1, displayName: "b"))
  }

  @Test func trailingSlashTrimmed() {
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/a"],
      branchNames: ["/wt/a": "feature/tools/"],
      collapsedPrefixes: []
    )
    // "feature/tools/" normalizes to ["feature", "tools"]. With only one
    // branch in the chain, no header is emitted and the leaf renders flat.
    #expect(rows == [.leaf(id: "/wt/a", depth: 0, displayName: nil)])
  }

  @Test func duplicateBranchNamesProduceSeparateLeaves() {
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/a", "/wt/b"],
      branchNames: ["/wt/a": "main", "/wt/b": "main"],
      collapsedPrefixes: []
    )
    // Two worktrees sharing the same single-component branch name must both render.
    #expect(
      rows == [
        .leaf(id: "/wt/a", depth: 0, displayName: nil),
        .leaf(id: "/wt/b", depth: 0, displayName: nil),
      ]
    )
  }

  @Test func mixedTopLevelAndGrouped() {
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/main", "/wt/a", "/wt/b", "/wt/c"],
      branchNames: [
        "/wt/main": "main",
        "/wt/a": "feature/a",
        "/wt/b": "feature/b",
        "/wt/c": "chore/x",
      ],
      collapsedPrefixes: []
    )
    // Alphabetical sort: `chore/x` < `feature/a` < `feature/b` < `main`.
    // `chore/x` has no sibling under `chore`, so it stays flat. `feature/*`
    // produces a header + 2 leaves. `main` is a top-level leaf.
    #expect(rows.count == 5)
    #expect(rows[0] == .leaf(id: "/wt/c", depth: 0, displayName: nil))
    if case .groupHeader(let prefix, _, let depth, _, _) = rows[1] {
      #expect(prefix == "feature")
      #expect(depth == 0)
    } else {
      Issue.record("Expected feature header at index 1, got \(rows[1])")
    }
    #expect(rows[2] == .leaf(id: "/wt/a", depth: 1, displayName: "a"))
    #expect(rows[3] == .leaf(id: "/wt/b", depth: 1, displayName: "b"))
    #expect(rows[4] == .leaf(id: "/wt/main", depth: 0, displayName: nil))
  }

  @Test func userExampleCollapsesSharedPrefixIntoOneHeader() {
    // The user's worked example: `feature/tools/a`, `feature/tools/b`, `b`
    // becomes a single `feature/tools` header (since `feature` has only
    // one child `tools`, the chain collapses) plus a top-level `b`.
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/a", "/wt/b", "/wt/b2"],
      branchNames: [
        "/wt/a": "feature/tools/a",
        "/wt/b": "feature/tools/b",
        "/wt/b2": "b",
      ],
      collapsedPrefixes: []
    )
    #expect(
      rows == [
        .leaf(id: "/wt/b2", depth: 0, displayName: nil),
        .groupHeader(
          prefix: "feature/tools",
          components: ["feature", "tools"],
          depth: 0,
          isCollapsed: false,
          leafDescendantIDs: ["/wt/a", "/wt/b"]
        ),
        .leaf(id: "/wt/a", depth: 1, displayName: "a"),
        .leaf(id: "/wt/b", depth: 1, displayName: "b"),
      ]
    )
  }

  @Test func groupingSortsBranchesAlphabeticallyIgnoringInputOrder() {
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/z", "/wt/a", "/wt/m"],
      branchNames: ["/wt/z": "zeta", "/wt/a": "alpha", "/wt/m": "mu"],
      collapsedPrefixes: []
    )
    #expect(
      rows == [
        .leaf(id: "/wt/a", depth: 0, displayName: nil),
        .leaf(id: "/wt/m", depth: 0, displayName: nil),
        .leaf(id: "/wt/z", depth: 0, displayName: nil),
      ]
    )
  }

  // MARK: - case-sensitive grouping.

  @Test func mixedCaseBranchesStaySeparate() {
    // Git refs are case-sensitive: `Feature/a` and `feature/b` are two
    // distinct branches and must never collapse into a single group. They
    // should each render as a flat row (single-child chain), not under a
    // shared `feature` header. Sort is case-insensitive so they land
    // adjacent, but the trie keeps them apart.
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/a", "/wt/b"],
      branchNames: ["/wt/a": "Feature/a", "/wt/b": "feature/b"],
      collapsedPrefixes: []
    )
    #expect(
      rows == [
        .leaf(id: "/wt/a", depth: 0, displayName: nil),
        .leaf(id: "/wt/b", depth: 0, displayName: nil),
      ]
    )
  }

  @Test func mixedCaseBranchesGroupSeparatelyAtSamePrefix() {
    // `Feature/a` + `Feature/b` and `feature/c` + `feature/d` each form
    // their own group; the two groups don't merge.
    let rows = SidebarBranchNesting.buildRows(
      itemIDs: ["/wt/a", "/wt/b", "/wt/c", "/wt/d"],
      branchNames: [
        "/wt/a": "Feature/a",
        "/wt/b": "Feature/b",
        "/wt/c": "feature/c",
        "/wt/d": "feature/d",
      ],
      collapsedPrefixes: []
    )
    // Case-insensitive sort puts the four branches in alphabetical order
    // (Feature/a, Feature/b, feature/c, feature/d), which means insertion
    // sees `Feature` before `feature`. Two separate groups emit.
    #expect(
      rows == [
        .groupHeader(
          prefix: "Feature",
          components: ["Feature"],
          depth: 0,
          isCollapsed: false,
          leafDescendantIDs: ["/wt/a", "/wt/b"]
        ),
        .leaf(id: "/wt/a", depth: 1, displayName: "a"),
        .leaf(id: "/wt/b", depth: 1, displayName: "b"),
        .groupHeader(
          prefix: "feature",
          components: ["feature"],
          depth: 0,
          isCollapsed: false,
          leafDescendantIDs: ["/wt/c", "/wt/d"]
        ),
        .leaf(id: "/wt/c", depth: 1, displayName: "c"),
        .leaf(id: "/wt/d", depth: 1, displayName: "d"),
      ]
    )
  }

  // MARK: - SidebarBranchNesting.aggregateIndicators.

  @Test func aggregatedIndicators_emptyLeavesReturnsEmpty() {
    let indicators = SidebarBranchNesting.aggregateIndicators(from: [])
    #expect(indicators == .empty)
  }

  @Test func aggregatedIndicators_unionNotification() {
    let snapshots: [SidebarBranchNesting.LeafIndicatorSnapshot] = [
      .init(hasUnseenNotifications: false, runningScriptColors: [], agents: []),
      .init(hasUnseenNotifications: true, runningScriptColors: [], agents: []),
    ]
    let indicators = SidebarBranchNesting.aggregateIndicators(from: snapshots)
    #expect(indicators.hasNotification)
  }

  @Test func aggregatedIndicators_unionScriptColorsAndDedup() {
    let snapshots: [SidebarBranchNesting.LeafIndicatorSnapshot] = [
      .init(hasUnseenNotifications: false, runningScriptColors: [.red, .blue], agents: []),
      .init(hasUnseenNotifications: false, runningScriptColors: [.red, .green], agents: []),
    ]
    let indicators = SidebarBranchNesting.aggregateIndicators(from: snapshots)
    #expect(indicators.runningScriptColors == [.red, .blue, .green])
  }

  @Test func aggregatedIndicators_capsAt3Colors() {
    let snapshots: [SidebarBranchNesting.LeafIndicatorSnapshot] = [
      .init(
        hasUnseenNotifications: false,
        runningScriptColors: [.red, .blue, .green, .yellow],
        agents: []
      )
    ]
    let indicators = SidebarBranchNesting.aggregateIndicators(from: snapshots)
    #expect(indicators.runningScriptColors.count == 3)
    #expect(indicators.runningScriptColors == [.red, .blue, .green])
  }

  @Test func aggregatedIndicators_capsAt3Agents() {
    let agents: [AgentPresenceFeature.AgentInstance] = [
      .init(agent: .claude, activity: .busy),
      .init(agent: .codex, activity: .idle),
      .init(agent: .kiro, activity: .awaitingInput),
      .init(agent: .pi, activity: .busy),
    ]
    let snapshots: [SidebarBranchNesting.LeafIndicatorSnapshot] = [
      .init(hasUnseenNotifications: false, runningScriptColors: [], agents: Array(agents.prefix(2))),
      .init(hasUnseenNotifications: false, runningScriptColors: [], agents: Array(agents.suffix(2))),
    ]
    let indicators = SidebarBranchNesting.aggregateIndicators(from: snapshots)
    #expect(indicators.agents.count == 3)
    #expect(indicators.agents == Array(agents.prefix(3)))
  }

  // MARK: - ancestorPrefixes.

  @Test func ancestorPrefixes_returnsAllButLast() {
    #expect(SidebarBranchNesting.ancestorPrefixes(of: "feature/tools/api") == ["feature", "feature/tools"])
  }

  @Test func ancestorPrefixes_emptyForSingleComponent() {
    #expect(SidebarBranchNesting.ancestorPrefixes(of: "main").isEmpty)
    #expect(SidebarBranchNesting.ancestorPrefixes(of: "").isEmpty)
  }

  @Test func ancestorPrefixes_normalizesEmptySegments() {
    #expect(SidebarBranchNesting.ancestorPrefixes(of: "/feature//tools/api") == ["feature", "feature/tools"])
  }
}
