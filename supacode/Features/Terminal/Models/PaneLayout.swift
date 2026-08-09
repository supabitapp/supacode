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

/// How a command-running terminal launches (scripts, prompts). Blocking
/// runners bypass zmx and die with the app; persistence strips this so a
/// stored layout can never replay a command.
nonisolated struct LaunchOverride: Equatable, Codable, Sendable {
  var command: String?
  var initialInput: String?
  var bypassZmx: Bool

  init(command: String? = nil, initialInput: String? = nil, bypassZmx: Bool = false) {
    self.command = command
    self.initialInput = initialInput
    self.bypassZmx = bypassZmx
  }
}

/// Terminal-specific persisted state; the generic layout never sees grids.
nonisolated struct TerminalContentState: Equatable, Codable, Sendable {
  let workingDirectory: String?
  let agents: [TerminalLayoutSnapshot.SurfaceAgentRecord]?
  let frozenGrid: FrozenGrid?
  /// Live-only launch override; the persistence path always strips it.
  let launch: LaunchOverride?

  private enum CodingKeys: String, CodingKey {
    case workingDirectory
    case agents
    case frozenGrid
  }

  init(
    workingDirectory: String?,
    agents: [TerminalLayoutSnapshot.SurfaceAgentRecord]? = nil,
    frozenGrid: FrozenGrid? = nil,
    launch: LaunchOverride? = nil
  ) {
    self.workingDirectory = workingDirectory
    self.agents = agents
    self.frozenGrid = frozenGrid
    self.launch = launch
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
    launch = nil
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
    try container.encodeIfPresent(agents, forKey: .agents)
    try container.encodeIfPresent(frozenGrid, forKey: .frozenGrid)
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

  /// A brand-new seed of the same kind, carrying no restorable state.
  var freshSeed: ContentState {
    switch self {
    case .terminal: .terminal(TerminalContentState(workingDirectory: nil))
    }
  }

  /// True for content that must die with the app: a blocking-script runner's
  /// process has no zmx session to reattach.
  var isEphemeral: Bool {
    switch self {
    case .terminal(let state): state.launch?.bypassZmx == true
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
  /// Live-only: a script tab owns its title and refuses renames. Blocking
  /// tabs are never persisted, so this stays off the wire.
  var isTitleLocked = false

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
    content: ContentSnapshot,
    isTitleLocked: Bool = false
  ) {
    self.id = id
    self.title = title
    self.customTitle = customTitle
    self.icon = icon
    self.tintColor = tintColor
    self.content = content
    self.isTitleLocked = isTitleLocked
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

  /// Sanitized user-supplied tab title; nil (clears the override) when
  /// nothing printable remains.
  static func normalizedCustomTitle(_ title: String) -> String? {
    // Blank control scalars, not the whole control-characters set, so emoji joiners survive.
    let scalars = title.unicodeScalars.map { scalar in
      scalar.properties.generalCategory == .control || CharacterSet.newlines.contains(scalar)
        ? UnicodeScalar(" ") : scalar
    }
    let sanitized = String(String.UnicodeScalarView(scalars))
    let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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
    let rawTabs = try container.decode([FailableDecodable<TabItem>].self, forKey: .tabs)
    // Duplicate tab IDs would trap IdentifiedArray; keep the first occurrence.
    var unique = IdentifiedArrayOf<TabItem>()
    for tab in rawTabs.compactMap(\.value) where unique[id: tab.id] == nil {
      unique.append(tab)
    }
    tabs = unique
    // Report dropped tabs so a destructive reader can refuse the partial file
    // rather than reap the missing session (its id is now absent).
    let droppedTabs = rawTabs.count - unique.count
    if droppedTabs > 0, let loss = decoder.userInfo[.layoutDecodeLoss] as? LayoutDecodeLoss {
      loss.droppedTabCount += droppedTabs
    }
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

nonisolated extension PaneLayout {
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

  /// Resolves a CLI / deeplink pane token: a pane's own id, or the id of a tab
  /// or content the pane hosts.
  func pane(forToken token: UUID) -> Pane? {
    if let pane = panes[id: PaneID(rawValue: token)] { return pane }
    if let pane = pane(containingTab: TabID(rawValue: token)) { return pane }
    if let resolved = tab(containingContent: ContentID(rawValue: token)) { return resolved.pane }
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

extension PaneLayout {
  /// The persistable layout: blocking-script tabs die with the app, so they
  /// (and any pane they empty) drop, retargeting selection to the nearest
  /// left survivor.
  func strippingEphemeralContent() -> PaneLayout {
    var result = self
    for pane in panes {
      guard pane.tabs.contains(where: { $0.content.state.isEphemeral }) else { continue }
      var kept = IdentifiedArrayOf<TabItem>()
      var selected = pane.selectedTabID
      for tab in pane.tabs {
        if tab.content.state.isEphemeral {
          if selected == tab.id {
            selected = kept.last?.id
          }
        } else {
          kept.append(tab)
        }
      }
      guard !kept.isEmpty else {
        if let node = result.tree.find(id: pane.id.rawValue) {
          result.tree = result.tree.removing(node)
        }
        result.panes.remove(id: pane.id)
        continue
      }
      var survivor = pane
      survivor.tabs = kept
      survivor.selectedTabID = selected.flatMap { kept[id: $0] != nil ? $0 : nil } ?? kept.first?.id
      result.panes[id: pane.id] = survivor
    }
    if let focused = result.focusedPaneID, result.panes[id: focused] == nil {
      result.focusedPaneID = result.panes.first?.id
    }
    return result
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

/// Accumulates content a tolerant layout decode silently dropped (unreadable
/// tabs), so a destructive reader can treat the file as lossy and keep the
/// orphan reaper from sweeping sessions the dropped content still owns. Install
/// one in the decoder's `userInfo` under `.layoutDecodeLoss` to collect it.
nonisolated final class LayoutDecodeLoss {
  var droppedTabCount = 0
}

nonisolated extension CodingUserInfoKey {
  /// Carries a `LayoutDecodeLoss` through a layout decode.
  static let layoutDecodeLoss = CodingUserInfoKey(rawValue: "sh.supacode.layoutDecodeLoss")!
}
