import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Namespace for the pure data layer behind the sidebar's branch-nesting
/// renderer. Holds the row enum + indicator value type + the trie builder.
/// Static-only "namespace enum" so call sites read as `SidebarBranchNesting.x`
/// rather than free symbols polluting the module scope.
enum SidebarBranchNesting {

  /// A single render row produced by `buildRows`. Group headers carry the
  /// slash-separated `prefix` plus all leaves they cover so the view can
  /// render aggregated indicators without re-walking the flat list.
  enum Row: Equatable, Sendable, Identifiable {
    /// - `prefix`: full slash-joined path from root. Used as the persistence key
    ///   for collapse state and as the SwiftUI identity.
    /// - `components`: the path components this header introduces relative to its
    ///   parent header (or to the root when at depth 0). When chain-collapsing
    ///   merges several nodes into one row, this carries every consumed
    ///   component (e.g. `["feature", "tools"]` when only `feature/tools/*`
    ///   branches exist), so the visible label can join them as `feature/tools`.
    ///   A regular nested header at depth N+1 below a header that already
    ///   consumed `feature` carries just `["tools"]`.
    case groupHeader(
      prefix: String,
      components: [String],
      depth: Int,
      isCollapsed: Bool,
      leafDescendantIDs: [SidebarItemID]
    )
    /// `displayName` is the trailing branch components below the leaf's
    /// ancestor headers (e.g. branch `feature/tools/a` rendered under
    /// `feature` > `tools` carries `"a"`). When grouping is off, the
    /// caller emits `displayName: nil` and the row falls back to the
    /// full branch name.
    case leaf(id: SidebarItemID, depth: Int, displayName: String?)

    /// Stable SwiftUI identity. Group headers carry the slash-joined prefix;
    /// leaves reuse their worktree ID. The `leaf:` / `group:` namespace prefix
    /// keeps the two disjoint when a worktree ID happens to look like a path
    /// prefix.
    var id: String {
      switch self {
      case .leaf(let id, _, _): "leaf:\(id)"
      case .groupHeader(let prefix, _, _, _, _): "group:\(prefix)"
      }
    }
  }

  /// Indicator union for a collapsed group header. Empty when the
  /// group is fully idle. Caps cardinalities at `maxIndicators` to
  /// keep the row width bounded; the underlying union is preserved
  /// across renders so the cap is deterministic.
  struct GroupIndicators: Equatable, Sendable {
    static let maxIndicators = 3

    var hasNotification: Bool
    var runningScriptColors: [RepositoryColor]
    var agents: [AgentPresenceFeature.AgentInstance]

    static let empty = GroupIndicators(
      hasNotification: false,
      runningScriptColors: [],
      agents: []
    )

    var isEmpty: Bool {
      !hasNotification && runningScriptColors.isEmpty && agents.isEmpty
    }
  }

  /// Snapshot of one leaf's group-relevant state, collected via per-leaf store
  /// scoping at the call site. Keeping aggregation purely data-in / data-out
  /// lets the view do the bounded observation work and lets the algorithm
  /// stay unit-testable.
  struct LeafIndicatorSnapshot: Equatable, Sendable {
    var hasUnseenNotifications: Bool
    var runningScriptColors: [RepositoryColor]
    var agents: [AgentPresenceFeature.AgentInstance]
  }

  /// Build a flat, render-ordered list of `Row` values for a single bucket.
  /// Branch names split on `/`; consecutive empty components are discarded so
  /// `feature//x`, `/feature/x`, and `feature/x/` all behave the same. A prefix
  /// only becomes a group header when it covers 2+ leaves; single-child
  /// prefixes stay flat to avoid headers that wrap a lone row. Branch
  /// components are treated case-sensitively because git refs themselves are
  /// case-sensitive: `Feature/x` and `feature/x` are distinct branches and
  /// must group separately.
  static func buildRows(
    itemIDs: [SidebarItemID],
    branchNames: [SidebarItemID: String],
    collapsedPrefixes: Set<String>
  ) -> [Row] {
    guard !itemIDs.isEmpty else { return [] }

    // Path grouping discards the bucket's user-defined order in favor of a stable
    // alphabetical sort by branch name. Custom drag-and-drop order is preserved
    // by the caller when grouping is off and is restored verbatim once the user
    // toggles grouping back off.
    let sortedIDs = itemIDs.sorted { lhs, rhs in
      let lhsKey = branchNames[lhs] ?? lhs.rawValue
      let rhsKey = branchNames[rhs] ?? rhs.rawValue
      return lhsKey.localizedCaseInsensitiveCompare(rhsKey) == .orderedAscending
    }

    var node = PathNode()
    for id in sortedIDs {
      let raw = branchNames[id] ?? ""
      let parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
      node.insert(id: id, components: parts)
    }

    var rows: [Row] = []
    node.emit(
      depth: 0,
      pathFromRoot: [],
      pathFromAncestorHeader: nil,
      collapsedPrefixes: collapsedPrefixes,
      into: &rows
    )
    return rows
  }

  /// Compute aggregated indicators for a collapsed group header by
  /// walking `leafSnapshots` in projection order. Empty when no descendant
  /// has indicators. Caps each cardinality at `GroupIndicators.maxIndicators`
  /// while preserving the first-seen insertion order.
  static func aggregateIndicators(
    from leafSnapshots: [LeafIndicatorSnapshot]
  ) -> GroupIndicators {
    var hasNotification = false
    var seenColors: Set<RepositoryColor> = []
    var colors: [RepositoryColor] = []
    var seenAgents: Set<AgentPresenceFeature.AgentInstance> = []
    var agents: [AgentPresenceFeature.AgentInstance] = []

    for snapshot in leafSnapshots {
      if snapshot.hasUnseenNotifications {
        hasNotification = true
      }
      for color in snapshot.runningScriptColors {
        if colors.count >= GroupIndicators.maxIndicators { break }
        if seenColors.insert(color).inserted {
          colors.append(color)
        }
      }
      for agent in snapshot.agents {
        if agents.count >= GroupIndicators.maxIndicators { break }
        if seenAgents.insert(agent).inserted {
          agents.append(agent)
        }
      }
    }

    return GroupIndicators(
      hasNotification: hasNotification,
      runningScriptColors: colors,
      agents: agents
    )
  }

  /// Walks `branchName`'s `/`-separated prefixes (e.g. `feature/tools/api`
  /// yields `feature` then `feature/tools`). Used by the reveal handler to
  /// uncollapse any ancestor prefix that would otherwise leave the selected
  /// row hidden, and by the persistence pruner to drop dead prefixes after
  /// a worktree is removed. Case-sensitive because git refs are.
  static func ancestorPrefixes(of branchName: String) -> [String] {
    let parts = branchName.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard parts.count > 1 else { return [] }
    var result: [String] = []
    result.reserveCapacity(parts.count - 1)
    for end in 1..<parts.count {
      result.append(parts[..<end].joined(separator: "/"))
    }
    return result
  }
}

// MARK: - Tree construction.

private struct PathNode {
  /// Children keyed by the raw `/`-separated component. Git refs are
  /// case-sensitive so `Feature/x` and `feature/x` are distinct branches and
  /// must land in distinct nodes.
  var children: [String: PathNode] = [:]
  /// Insertion-order list of keys, used for deterministic emit order.
  var childOrder: [String] = []
  /// Worktree IDs that land on this exact node. A list rather than a single
  /// optional so two worktrees sharing the same display path don't drop one.
  var leafIDs: [SidebarItemID] = []

  mutating func insert(id: SidebarItemID, components: [String]) {
    guard let head = components.first else {
      // Empty branch name lands here. Treat as a top-level leaf without grouping.
      leafIDs.append(id)
      return
    }
    var child = children[head] ?? PathNode()
    let isFreshSlot = child.leafIDs.isEmpty && child.children.isEmpty
    if components.count == 1 {
      child.leafIDs.append(id)
    } else {
      child.insert(id: id, components: Array(components.dropFirst()))
    }
    children[head] = child
    if isFreshSlot {
      childOrder.append(head)
    }
  }

  /// Emit rows by walking the trie, compacting any chain of single-child
  /// internal nodes into a single header at the deepest shared prefix.
  /// A node only produces a header when it actually branches (>= 2 children,
  /// or children + leafIDs at the same node). A pure single-branch chain
  /// (e.g. `feature/tools/x` alone) renders as a flat leaf with no header.
  func emit(
    depth: Int,
    pathFromRoot: [String],
    pathFromAncestorHeader: [String]?,
    collapsedPrefixes: Set<String>,
    into rows: inout [SidebarBranchNesting.Row]
  ) {
    // Leaves that terminate at this exact node render first so a `feature`
    // branch precedes any `feature/tools` descendants when both exist.
    for leafID in leafIDs {
      rows.append(
        .leaf(id: leafID, depth: depth, displayName: makeDisplayName(pathFromAncestorHeader))
      )
    }

    for key in childOrder {
      guard let child = children[key] else { continue }
      // Walk down through single-link internal nodes (one child, no leaf
      // here) so a `feature/tools/x` chain collapses into one row instead
      // of three nested headers.
      var current = child
      var addedComponents = [key]
      while current.leafIDs.isEmpty && current.children.count == 1,
        let nextKey = current.childOrder.first,
        let nextChild = current.children[nextKey]
      {
        addedComponents.append(nextKey)
        current = nextChild
      }

      let branchesAtCurrent = current.children.count + (current.leafIDs.isEmpty ? 0 : 1)
      let nextPathFromRoot = pathFromRoot + addedComponents

      if branchesAtCurrent >= 2 {
        // Real branching point: emit a header and recurse with the header
        // ancestry reset so inner leaves only show the path below it.
        let prefix = nextPathFromRoot.joined(separator: "/")
        let isCollapsed = collapsedPrefixes.contains(prefix)
        var descendants: [SidebarItemID] = []
        current.collectLeafIDs(into: &descendants)
        rows.append(
          .groupHeader(
            prefix: prefix,
            components: addedComponents,
            depth: depth,
            isCollapsed: isCollapsed,
            leafDescendantIDs: descendants
          )
        )
        if !isCollapsed {
          current.emit(
            depth: depth + 1,
            pathFromRoot: nextPathFromRoot,
            pathFromAncestorHeader: [],
            collapsedPrefixes: collapsedPrefixes,
            into: &rows
          )
        }
      } else {
        // Single-link chain terminating in a pure leaf (or a multi-leaf
        // duplicate). No header is emitted at this prefix; the leaves render
        // with their tail components relative to the nearest header above.
        let nextPathFromHeader = pathFromAncestorHeader.map { $0 + addedComponents }
        let displayName = makeDisplayName(nextPathFromHeader)
        for leafID in current.leafIDs {
          rows.append(.leaf(id: leafID, depth: depth, displayName: displayName))
        }
      }
    }
  }

  func collectLeafIDs(into result: inout [SidebarItemID]) {
    result.append(contentsOf: leafIDs)
    for key in childOrder {
      children[key]?.collectLeafIDs(into: &result)
    }
  }

  private func makeDisplayName(_ pathFromAncestorHeader: [String]?) -> String? {
    guard let pathFromAncestorHeader, !pathFromAncestorHeader.isEmpty else { return nil }
    return pathFromAncestorHeader.joined(separator: "/")
  }
}
