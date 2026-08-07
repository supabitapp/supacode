import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

nonisolated private let migrationLogger = SupaLogger("Layouts")

/// One worktree's persisted layout plus the write-once pre-migration original.
nonisolated struct LayoutRecord: Equatable, Codable, Sendable {
  var layout: PaneLayout
  /// The v1 snapshot verbatim, written once at migration and never read by the
  /// app; enables rollback tooling.
  let origin: TerminalLayoutSnapshot?

  private enum CodingKeys: String, CodingKey {
    case layout
    case origin
  }

  init(layout: PaneLayout, origin: TerminalLayoutSnapshot? = nil) {
    self.layout = layout
    self.origin = origin
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    layout = try container.decode(PaneLayout.self, forKey: .layout)
    // `try?` so origin rot can never take the live layout down with it.
    origin =
      (try? container.decodeIfPresent(TerminalLayoutSnapshot.self, forKey: .origin)) ?? nil
  }
}

/// The layouts.json v2 shape: a version stamp over per-worktree records.
nonisolated struct LayoutsFile: Equatable, Codable, Sendable {
  static let currentSchemaVersion = 2

  var schemaVersion: Int
  var worktrees: [String: LayoutRecord]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case worktrees
  }

  init(schemaVersion: Int = LayoutsFile.currentSchemaVersion, worktrees: [String: LayoutRecord]) {
    self.schemaVersion = schemaVersion
    self.worktrees = worktrees
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    // Element-wise so one rotten worktree entry drops that entry, not the file.
    let raw = try container.decode([String: FailableDecodable<LayoutRecord>].self, forKey: .worktrees)
    worktrees = raw.compactMapValues(\.value)
    // A dropped entry loses its session references to the orphan reaper; the
    // loss must at least be diagnosable.
    let dropped = raw.keys.filter { worktrees[$0] == nil }
    if !dropped.isEmpty {
      migrationLogger.error("Dropped unreadable layout entries: \(dropped.sorted())")
    }
  }
}

/// Transforms v1 layouts (splits-per-tab) into the v2 pane topology.
///
/// Mapping rule: the selected tab's split tree becomes the pane arrangement,
/// one pane per leaf; every other tab lands in the pane of the selected tab's
/// focused leaf; a multi-leaf non-selected tab fans its leaves into adjacent
/// tabs. The old tab's ID stays on the tab at its focused leaf; fanned
/// siblings mint their content's UUID as tab ID, re-establishing the
/// documented initial-surface-equals-tab-ID invariant. No content is dropped.
nonisolated enum LayoutsMigrator {
  /// A migrated worktree; `nil` layout output never happens, empty input maps
  /// to an empty record.
  static func migrate(_ snapshot: TerminalLayoutSnapshot) -> LayoutRecord {
    var builder = Builder()
    let tabs = snapshot.tabs
    guard !tabs.isEmpty else {
      return LayoutRecord(layout: PaneLayout(), origin: snapshot)
    }
    let selectedIndex = max(0, min(snapshot.selectedTabIndex, tabs.count - 1))
    let selected = tabs[selectedIndex]
    // Old tab IDs commonly equal their initial leaf's surface UUID; reserve
    // them so a fanned sibling cannot claim an identity leaf's ID first.
    builder.reservedTabIDs = Set(tabs.compactMap(\.id))

    // The selected tab's split tree becomes the pane arrangement.
    let tree = builder.buildTree(from: selected.layout)
    let selectedLeaves = selected.layout.leaves
    let focusedLeafIndex = max(0, min(selected.focusedLeafIndex, selectedLeaves.count - 1))
    for (index, leaf) in selectedLeaves.enumerated() {
      let carriesTabIdentity = index == focusedLeafIndex
      builder.appendTab(
        toPaneAt: index,
        Self.tabItem(
          from: leaf,
          tab: selected,
          carriesTabIdentity: carriesTabIdentity,
          builder: &builder
        )
      )
    }
    let homePaneIndex = focusedLeafIndex

    // Every other tab lands in the focused leaf's pane, in tab order; fanned
    // leaves of a multi-leaf tab stay adjacent, its focused leaf carrying the
    // tab identity.
    for (index, tab) in tabs.enumerated() where index != selectedIndex {
      let leaves = tab.layout.leaves
      let tabFocusedIndex = max(0, min(tab.focusedLeafIndex, leaves.count - 1))
      for (leafIndex, leaf) in leaves.enumerated() {
        builder.appendTab(
          toPaneAt: homePaneIndex,
          Self.tabItem(
            from: leaf,
            tab: tab,
            carriesTabIdentity: leafIndex == tabFocusedIndex,
            builder: &builder
          )
        )
      }
    }

    var panes = IdentifiedArrayOf<Pane>()
    for (index, paneID) in builder.paneIDs.enumerated() {
      let tabs = builder.tabsByPane[index] ?? []
      // Each pane's first tab is its own leaf's tab, so first-tab selection
      // keeps the selected tab selected in the home pane too.
      panes.append(
        Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: tabs), selectedTabID: tabs.first?.id)
      )
    }
    let layout = PaneLayout(
      tree: tree,
      panes: panes,
      focusedPaneID: builder.paneIDs.indices.contains(homePaneIndex)
        ? builder.paneIDs[homePaneIndex] : builder.paneIDs.first
    )
    return LayoutRecord(layout: layout, origin: snapshot)
  }

  /// Builds the v2 file from a v1 dictionary; every worktree keeps every
  /// content ID.
  ///
  /// Runner contract: gate each record on `layout.isConsistent` before serving
  /// it; compute the orphan reaper's known set as the union of
  /// `layout.allContentIDs` and `origin.allSurfaceIDs`; treat a file whose
  /// `schemaVersion` exceeds `currentSchemaVersion` as read-only.
  static func migrate(_ legacy: [String: TerminalLayoutSnapshot]) -> LayoutsFile {
    LayoutsFile(worktrees: legacy.mapValues { migrate($0) })
  }

  private static func tabItem(
    from leaf: TerminalLayoutSnapshot.SurfaceSnapshot,
    tab: TerminalLayoutSnapshot.TabSnapshot,
    carriesTabIdentity: Bool,
    builder: inout Builder
  ) -> TabItem {
    let contentUUID = leaf.id ?? UUID()
    let content = ContentSnapshot(
      id: ContentID(rawValue: contentUUID),
      state: .terminal(
        TerminalContentState(
          workingDirectory: leaf.workingDirectory,
          agents: leaf.agents
        )
      )
    )
    // The identity-carrying tab keeps the old tab's ID and full metadata;
    // fanned siblings mint their content UUID and inherit only presentation,
    // never the custom title. A sibling may not claim a reserved old tab ID:
    // tab IDs commonly equal the initial leaf's surface UUID, and identity
    // must not be stolen by leaf order.
    let requestedID = carriesTabIdentity ? (tab.id ?? contentUUID) : contentUUID
    let isTaken =
      builder.usedTabIDs.contains(requestedID)
      || (!carriesTabIdentity && builder.reservedTabIDs.contains(requestedID))
    let tabID = isTaken ? UUID() : requestedID
    if isTaken {
      migrationLogger.warning(
        "Reminted migrated tab ID \(requestedID) -> \(tabID) (identity: \(carriesTabIdentity))"
      )
    }
    builder.usedTabIDs.insert(tabID)
    return TabItem(
      id: TerminalTabID(rawValue: tabID),
      title: tab.title,
      customTitle: carriesTabIdentity ? tab.customTitle : nil,
      icon: tab.icon,
      tintColor: tab.tintColor,
      content: content
    )
  }

  /// Accumulates panes while the selected tab's tree is mirrored.
  private struct Builder {
    var paneIDs: [PaneID] = []
    var tabsByPane: [Int: [TabItem]] = [:]
    var usedTabIDs: Set<UUID> = []
    var reservedTabIDs: Set<UUID> = []

    mutating func appendTab(toPaneAt index: Int, _ tab: TabItem) {
      tabsByPane[index, default: []].append(tab)
    }

    /// Mirrors the v1 layout node into a tree of freshly minted pane IDs,
    /// leaves in traversal order.
    mutating func buildTree(from node: TerminalLayoutSnapshot.LayoutNode) -> SplitTree<PaneID> {
      SplitTree(root: buildNode(from: node))
    }

    private mutating func buildNode(
      from node: TerminalLayoutSnapshot.LayoutNode
    ) -> SplitTree<PaneID>.Node {
      switch node {
      case .leaf:
        let paneID = PaneID()
        paneIDs.append(paneID)
        return .leaf(view: paneID)
      case .split(let split):
        let left = buildNode(from: split.left)
        let right = buildNode(from: split.right)
        let direction: SplitTree<PaneID>.Direction =
          switch split.direction {
          case .horizontal: .horizontal
          case .vertical: .vertical
          }
        return .split(
          SplitTree<PaneID>.Split(
            direction: direction,
            ratio: split.ratio,
            left: left,
            right: right
          )
        )
      }
    }
  }
}

nonisolated extension TerminalLayoutSnapshot.LayoutNode {
  /// Leaves in traversal order, matching `leafSurfaceIDs`.
  fileprivate var leaves: [TerminalLayoutSnapshot.SurfaceSnapshot] {
    switch self {
    case .leaf(let surface):
      return [surface]
    case .split(let split):
      return split.left.leaves + split.right.leaves
    }
  }
}
