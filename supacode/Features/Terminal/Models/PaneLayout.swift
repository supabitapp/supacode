import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

/// Identity of a pane, a split-tree leaf holding a strip of tabs.
nonisolated struct PaneID: Hashable, Identifiable, Codable, Sendable {
  let rawValue: UUID

  init() {
    rawValue = UUID()
  }

  init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  var id: UUID { rawValue }

  init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(UUID.self)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// What kind of content a tab hosts; additive for future kinds.
nonisolated enum ContentKind: String, Codable, Sendable {
  case terminal
}

/// Terminal-specific persisted state; the generic layout never sees grids.
nonisolated struct TerminalContentState: Equatable, Codable, Sendable {
  let workingDirectory: String?
  let agents: [TerminalLayoutSnapshot.SurfaceAgentRecord]?
  let frozenGrid: FrozenGrid?

  private enum CodingKeys: String, CodingKey {
    case workingDirectory
    case agents
    case frozenGrid
  }

  init(
    workingDirectory: String?,
    agents: [TerminalLayoutSnapshot.SurfaceAgentRecord]? = nil,
    frozenGrid: FrozenGrid? = nil
  ) {
    self.workingDirectory = workingDirectory
    self.agents = agents
    self.frozenGrid = frozenGrid
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
    // `try?` so a future shape change drops the field, not the whole entry.
    agents =
      (try? container.decodeIfPresent(
        [TerminalLayoutSnapshot.SurfaceAgentRecord].self, forKey: .agents
      )) ?? nil
    frozenGrid = (try? container.decodeIfPresent(FrozenGrid.self, forKey: .frozenGrid)) ?? nil
  }
}

/// Kind-keyed content payload; each case owns its kind's persisted state.
nonisolated enum ContentState: Equatable, Codable, Sendable {
  case terminal(TerminalContentState)

  private enum CodingKeys: String, CodingKey {
    case kind
    case terminal
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(ContentKind.self, forKey: .kind) {
    case .terminal:
      self = .terminal(try container.decode(TerminalContentState.self, forKey: .terminal))
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .terminal(let state):
      try container.encode(ContentKind.terminal, forKey: .kind)
      try container.encode(state, forKey: .terminal)
    }
  }

  var kind: ContentKind {
    switch self {
    case .terminal: .terminal
    }
  }
}

/// Identity of a tab's content, stable across hibernation and relaunch; the
/// zmx session name is derived from it for terminals.
nonisolated struct ContentID: Hashable, Identifiable, Codable, Sendable {
  let rawValue: UUID

  init() {
    rawValue = UUID()
  }

  init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  var id: UUID { rawValue }

  init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(UUID.self)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A tab's content: stable identity plus the kind-specific persisted state.
nonisolated struct ContentSnapshot: Equatable, Codable, Sendable {
  let id: ContentID
  let state: ContentState

  private enum CodingKeys: String, CodingKey {
    case id
    case state
  }

  var kind: ContentKind { state.kind }
}

/// One tab in a pane's strip, hosting exactly one content.
nonisolated struct TabItem: Equatable, Identifiable, Codable, Sendable {
  let id: TabID
  var title: String
  var customTitle: String?
  var icon: String?
  var tintColor: RepositoryColor?
  var content: ContentSnapshot

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case customTitle
    case icon
    case tintColor
    case content
  }

  init(
    id: TabID,
    title: String,
    customTitle: String? = nil,
    icon: String? = nil,
    tintColor: RepositoryColor? = nil,
    content: ContentSnapshot
  ) {
    self.id = id
    self.title = title
    self.customTitle = customTitle
    self.icon = icon
    self.tintColor = tintColor
    self.content = content
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(TabID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
    icon = try container.decodeIfPresent(String.self, forKey: .icon)
    // `try?` so a tint value the running build doesn't recognize drops the
    // field, not the tab.
    tintColor = (try? container.decodeIfPresent(RepositoryColor.self, forKey: .tintColor)) ?? nil
    content = try container.decode(ContentSnapshot.self, forKey: .content)
  }
}

/// A split-tree leaf: an ordered strip of tabs with one selected.
nonisolated struct Pane: Equatable, Identifiable, Codable, Sendable {
  let id: PaneID
  var tabs: IdentifiedArrayOf<TabItem>
  var selectedTabID: TabID?

  private enum CodingKeys: String, CodingKey {
    case id
    case tabs
    case selectedTabID
  }

  init(id: PaneID, tabs: IdentifiedArrayOf<TabItem> = [], selectedTabID: TabID? = nil) {
    self.id = id
    self.tabs = tabs
    // Mirror decode's repair so both construction paths satisfy the invariant.
    self.selectedTabID = selectedTabID.flatMap { tabs[id: $0] != nil ? $0 : nil } ?? tabs.first?.id
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(PaneID.self, forKey: .id)
    // Element-wise so a tab a rollback build cannot read (a future content
    // kind) drops that tab, not the whole layout.
    let decodedTabs = try container
      .decode([FailableDecodable<TabItem>].self, forKey: .tabs)
      .compactMap(\.value)
    // Duplicate tab IDs would trap IdentifiedArray; keep the first occurrence.
    var unique = IdentifiedArrayOf<TabItem>()
    for tab in decodedTabs where unique[id: tab.id] == nil {
      unique.append(tab)
    }
    tabs = unique
    let decodedSelection = try container.decodeIfPresent(TabID.self, forKey: .selectedTabID)
    selectedTabID = decodedSelection.flatMap { unique[id: $0] != nil ? $0 : nil } ?? unique.first?.id
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(Array(tabs), forKey: .tabs)
    try container.encodeIfPresent(selectedTabID, forKey: .selectedTabID)
  }

  var selectedTab: TabItem? {
    selectedTabID.flatMap { tabs[id: $0] }
  }
}

/// A worktree's whole layout: the split structure over panes, the panes
/// themselves, and focus. In-memory shape == persisted shape.
nonisolated struct PaneLayout: Equatable, Codable, Sendable {
  var tree: SplitTree<PaneID>
  var panes: IdentifiedArrayOf<Pane>
  var focusedPaneID: PaneID?

  private enum CodingKeys: String, CodingKey {
    case tree
    case panes
    case focusedPaneID
  }

  init(
    tree: SplitTree<PaneID> = SplitTree(),
    panes: IdentifiedArrayOf<Pane> = [],
    focusedPaneID: PaneID? = nil
  ) {
    self.tree = tree
    self.panes = panes
    // Mirror decode's repair so both construction paths satisfy the invariant.
    self.focusedPaneID =
      focusedPaneID.flatMap { panes[id: $0] != nil ? $0 : nil } ?? panes.first?.id
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    tree = try container.decode(SplitTree<PaneID>.self, forKey: .tree)
    let decodedPanes = try container.decode([Pane].self, forKey: .panes)
    var unique = IdentifiedArrayOf<Pane>()
    for pane in decodedPanes where unique[id: pane.id] == nil {
      unique.append(pane)
    }
    panes = unique
    let decodedFocus = try container.decodeIfPresent(PaneID.self, forKey: .focusedPaneID)
    focusedPaneID = decodedFocus.flatMap { unique[id: $0] != nil ? $0 : nil } ?? unique.first?.id
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(tree, forKey: .tree)
    try container.encode(Array(panes), forKey: .panes)
    try container.encodeIfPresent(focusedPaneID, forKey: .focusedPaneID)
  }
}

extension PaneLayout {
  /// The pane a tab lives in.
  func pane(containingTab tabID: TabID) -> Pane? {
    panes.first { $0.tabs[id: tabID] != nil }
  }

  /// The pane and tab hosting a content.
  func tab(containingContent contentID: ContentID) -> (pane: Pane, tab: TabItem)? {
    for pane in panes {
      if let tab = pane.tabs.first(where: { $0.content.id == contentID }) {
        return (pane, tab)
      }
    }
    return nil
  }

  /// Every content identity in the layout, tree order not guaranteed.
  var allContentIDs: [ContentID] {
    panes.flatMap { pane in pane.tabs.map(\.content.id) }
  }

  /// Structural invariants: tree leaves and panes agree one-to-one, panes are
  /// never empty (closing the last tab closes the pane), every selection
  /// resolves, and focus exists iff panes do. Decode repairs dangling
  /// references but does NOT reconcile tree against panes; loaders and the
  /// migrator gate on this predicate and fall back on failure.
  var isConsistent: Bool {
    let leafIDs = tree.leaves()
    guard Set(leafIDs).count == leafIDs.count else { return false }
    guard Set(leafIDs) == Set(panes.ids) else { return false }
    for pane in panes {
      guard !pane.tabs.isEmpty else { return false }
      guard let selected = pane.selectedTabID, pane.tabs[id: selected] != nil else { return false }
    }
    if let focusedPaneID {
      guard panes[id: focusedPaneID] != nil else { return false }
    } else if !panes.isEmpty {
      return false
    }
    let tabIDs = panes.flatMap { pane in pane.tabs.map(\.id) }
    guard Set(tabIDs).count == tabIDs.count else { return false }
    let contentIDs = allContentIDs
    return Set(contentIDs).count == contentIDs.count
  }
}

/// Decodes a value or swallows its failure, so one unreadable element in a
/// collection drops that element rather than the container.
nonisolated struct FailableDecodable<Value: Decodable>: Decodable {
  let value: Value?

  init(from decoder: any Decoder) {
    value = try? Value(from: decoder)
  }
}
