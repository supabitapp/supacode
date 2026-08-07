import AppKit
import ComposableArchitecture
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

/// Recipe for a new tab: identity (minted when nil), content seed, spawn
/// geometry, and whether the tab takes selection and pane focus.
nonisolated struct NewTabSpec: Equatable, Sendable {
  let tabID: TerminalTabID?
  let contentID: ContentID?
  let title: String
  let initialState: TerminalContentState
  let geometry: ContentGeometry
  let select: Bool

  init(
    tabID: TerminalTabID? = nil,
    contentID: ContentID? = nil,
    title: String,
    initialState: TerminalContentState,
    geometry: ContentGeometry,
    select: Bool = true
  ) {
    self.tabID = tabID
    self.contentID = contentID
    self.title = title
    self.initialState = initialState
    self.geometry = geometry
    self.select = select
  }
}

/// Creates live content for a tab; the real surface-backed factory is wired
/// by the integration layer.
nonisolated struct LayoutContentFactory: Sendable {
  var make: @MainActor @Sendable (ContentID, TerminalContentState) -> any TabContent
}

extension LayoutContentFactory: DependencyKey {
  // `unimplemented(_:placeholder:)` cannot mint the id-bound placeholder, so
  // this hand-rolls the same report-and-return contract.
  static let liveValue = LayoutContentFactory(
    make: { contentID, initialState in
      reportIssue("LayoutContentFactory.make is unimplemented")
      return UnimplementedTabContent(id: contentID, state: initialState)
    }
  )

  static let testValue = liveValue
}

extension DependencyValues {
  var layoutContentFactory: LayoutContentFactory {
    get { self[LayoutContentFactory.self] }
    set { self[LayoutContentFactory.self] = newValue }
  }
}

/// Zoom behavior on focus changes; the integration layer injects the live
/// Ghostty config read.
nonisolated struct SplitZoomPolicy: Sendable {
  /// True keeps the zoom on the newly focused pane; false clears it.
  var preservesZoomOnNavigation: @MainActor @Sendable () -> Bool
}

extension SplitZoomPolicy: DependencyKey {
  // Matches GhosttyRuntime's no-config fallback until the real read is wired.
  static let liveValue = SplitZoomPolicy(preservesZoomOnNavigation: { false })

  static let testValue = liveValue
}

/// Inert content returned by the unimplemented factory placeholder.
private final class UnimplementedTabContent: TabContent {
  let id: ContentID
  let kind: ContentKind = .terminal
  private let state: TerminalContentState

  init(id: ContentID, state: TerminalContentState) {
    self.id = id
    self.state = state
  }

  var renderer: NSView? { nil }

  func startSession(at geometry: ContentGeometry) {}

  func hibernate() {}

  func snapshot() -> ContentSnapshot {
    ContentSnapshot(id: id, state: .terminal(state))
  }
}

/// Owns one worktree's pane and tab topology: the split tree over panes, each
/// pane's tab strip and selection, focus, and zoom. Content lifecycles go
/// through `ContentRuntime`; state stays value-only.
@Reducer
struct LayoutFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let id: Worktree.ID
    var layout: PaneLayout
  }

  /// Events pushed by the content-runtime plumbing.
  nonisolated enum RuntimeEvent: Equatable, Sendable {
    case killConfirmed(id: ContentID)
    case titleChanged(id: ContentID, title: String)
  }

  /// What `focusPane` aims at. One payload instead of two `focusPane`
  /// overloads: Swift cannot disambiguate overloaded case names in patterns.
  nonisolated enum FocusTarget: Equatable, Sendable {
    case pane(PaneID)
    case direction(SplitTree<PaneID>.FocusDirection)
  }

  enum Action: Equatable, Sendable {
    case newTab(inPane: PaneID, spec: NewTabSpec)
    case splitPane(id: PaneID, direction: SplitTree<PaneID>.NewDirection, spec: NewTabSpec)
    case closeTab(id: TerminalTabID)
    case closePane(id: PaneID)
    case selectTab(id: TerminalTabID)
    case renameTab(id: TerminalTabID, title: String)
    case focusPane(FocusTarget)
    case moveTab(id: TerminalTabID, toPane: PaneID, index: Int)
    case resizePane(node: SplitTree<PaneID>.Node, ratio: Double)
    case equalizePanes
    case toggleZoom(paneID: PaneID)
    case hibernateTab(id: TerminalTabID)
    case wakeTab(id: TerminalTabID)
    case runtime(RuntimeEvent)
  }

  private static let logger = SupaLogger("LayoutFeature")

  // Ratio drags and title reports arrive at frame rate and cannot alter
  // structure; exempt them from the per-action layout walk.
  private static func isExemptFromConsistencyCheck(_ action: Action) -> Bool {
    switch action {
    case .resizePane, .runtime(.titleChanged):
      return true
    default:
      return false
    }
  }

  @Dependency(ContentRuntime.self) private var contentRuntime
  @Dependency(LayoutContentFactory.self) private var layoutContentFactory
  @Dependency(SplitZoomPolicy.self) private var splitZoomPolicy
  @Dependency(\.uuid) private var uuid

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      // Single invariant gate: every action must leave the layout consistent.
      // The assert compiles out in release, where the log is the only witness.
      defer {
        if !Self.isExemptFromConsistencyCheck(action) {
          let consistent = state.layout.isConsistent
          assert(consistent, "Inconsistent layout after \(action).")
          if !consistent {
            Self.logger.error("Inconsistent layout after \(action).")
          }
        }
      }
      switch action {
      case .newTab(let paneID, let spec):
        return reduceNewTab(&state, paneID: paneID, spec: spec)
      case .splitPane(let anchorID, let direction, let spec):
        return reduceSplitPane(&state, anchorID: anchorID, direction: direction, spec: spec)
      case .closeTab(let tabID):
        return reduceCloseTab(&state, tabID: tabID)
      case .closePane(let paneID):
        return reduceClosePane(&state, paneID: paneID)
      case .selectTab(let tabID):
        return reduceSelectTab(&state, tabID: tabID)
      case .renameTab(let tabID, let title):
        return reduceRenameTab(&state, tabID: tabID, title: title)
      case .focusPane(let target):
        return reduceFocusPane(&state, target: target)
      case .moveTab(let tabID, let targetPaneID, let index):
        return reduceMoveTab(&state, tabID: tabID, targetPaneID: targetPaneID, index: index)
      case .resizePane(let node, let ratio):
        return reduceResizePane(&state, node: node, ratio: ratio)
      case .equalizePanes:
        state.layout.tree = state.layout.tree.equalized()
        return .none
      case .toggleZoom(let paneID):
        return reduceToggleZoom(&state, paneID: paneID)
      case .hibernateTab(let tabID):
        return reduceHibernateTab(&state, tabID: tabID)
      case .wakeTab(let tabID):
        return reduceWakeTab(&state, tabID: tabID)
      case .runtime(let event):
        return reduceRuntimeEvent(&state, event: event)
      }
    }
  }
}

// MARK: - Tabs.

extension LayoutFeature {
  private func reduceNewTab(_ state: inout State, paneID: PaneID, spec: NewTabSpec) -> Effect<Action> {
    // An emptied layout can only be re-entered here, by materializing the
    // target pane as the new root; validate everything before mutating.
    let bootstraps = state.layout.panes.isEmpty
    guard bootstraps || state.layout.panes[id: paneID] != nil else {
      Self.logger.warning("newTab into unknown pane \(paneID.rawValue)")
      return .none
    }
    guard let identity = mintedIdentity(in: state.layout, for: spec, operation: "newTab") else { return .none }
    guard provisionContent(id: identity.contentID, from: spec, operation: "newTab") else { return .none }
    if bootstraps {
      state.layout.tree = SplitTree(view: paneID)
      state.layout.panes.append(Pane(id: paneID))
    }
    guard var pane = state.layout.panes[id: paneID] else {
      // Unreachable behind the guards above; reap the started session anyway.
      contentRuntime.remove(identity.contentID, tombstone: true)
      return .none
    }
    let tab = TabItem(
      id: identity.tabID,
      title: spec.title,
      content: ContentSnapshot(id: identity.contentID, state: .terminal(spec.initialState))
    )
    // Mirror TerminalTabManager.createTab: insert after the selection;
    // background tabs append so a run of them keeps its order.
    if spec.select, let selectedID = pane.selectedTabID, let index = pane.tabs.index(id: selectedID) {
      pane.tabs.insert(tab, at: index + 1)
    } else {
      pane.tabs.append(tab)
    }
    // Still select when nothing was selected: a pane must have a visible tab.
    if spec.select || pane.selectedTabID == nil {
      pane.selectedTabID = tab.id
    }
    state.layout.panes[id: paneID] = pane
    if spec.select {
      focus(&state, paneID: paneID)
    } else if state.layout.focusedPaneID == nil {
      // A background tab must not leave a populated layout unfocused.
      state.layout.focusedPaneID = paneID
    }
    return .none
  }

  private func reduceCloseTab(_ state: inout State, tabID: TerminalTabID) -> Effect<Action> {
    guard var pane = state.layout.pane(containingTab: tabID), let index = pane.tabs.index(id: tabID) else {
      return .none
    }
    // Tombstoned until the async zmx kill (wired at integration) confirms.
    contentRuntime.remove(pane.tabs[index].content.id, tombstone: true)
    pane.tabs.remove(at: index)
    guard !pane.tabs.isEmpty else {
      collapse(&state, paneID: pane.id)
      return .none
    }
    if pane.selectedTabID == tabID {
      // Mirror TerminalTabManager.closeTab: previous tab, else the first.
      pane.selectedTabID = index > 0 ? pane.tabs[index - 1].id : pane.tabs.first?.id
    }
    state.layout.panes[id: pane.id] = pane
    return .none
  }

  private func reduceMoveTab(
    _ state: inout State,
    tabID: TerminalTabID,
    targetPaneID: PaneID,
    index: Int
  ) -> Effect<Action> {
    guard var source = state.layout.pane(containingTab: tabID), let sourceIndex = source.tabs.index(id: tabID) else {
      return .none
    }
    if source.id == targetPaneID {
      let tab = source.tabs.remove(at: sourceIndex)
      source.tabs.insert(tab, at: min(max(index, 0), source.tabs.count))
      // Reordering deliberately selects the dragged tab, unlike the keyboard
      // move in TerminalTabManager.
      source.selectedTabID = tab.id
      state.layout.panes[id: source.id] = source
      focus(&state, paneID: source.id)
      return .none
    }
    guard var target = state.layout.panes[id: targetPaneID] else { return .none }
    let tab = source.tabs.remove(at: sourceIndex)
    target.tabs.insert(tab, at: min(max(index, 0), target.tabs.count))
    target.selectedTabID = tab.id
    state.layout.panes[id: targetPaneID] = target
    if source.tabs.isEmpty {
      // Same emptied-pane path as closing a pane's last tab.
      collapse(&state, paneID: source.id)
    } else {
      if source.selectedTabID == tabID {
        source.selectedTabID = sourceIndex > 0 ? source.tabs[sourceIndex - 1].id : source.tabs.first?.id
      }
      state.layout.panes[id: source.id] = source
    }
    focus(&state, paneID: targetPaneID)
    return .none
  }

  private func reduceSelectTab(_ state: inout State, tabID: TerminalTabID) -> Effect<Action> {
    guard var pane = state.layout.pane(containingTab: tabID) else { return .none }
    pane.selectedTabID = tabID
    state.layout.panes[id: pane.id] = pane
    focus(&state, paneID: pane.id)
    return .none
  }

  private func reduceRenameTab(_ state: inout State, tabID: TerminalTabID, title: String) -> Effect<Action> {
    guard var pane = state.layout.pane(containingTab: tabID) else { return .none }
    // Empty rename clears the override; normalization mirrors the tab manager.
    pane.tabs[id: tabID]?.customTitle = TerminalTabManager.normalizedCustomTitle(title)
    state.layout.panes[id: pane.id] = pane
    return .none
  }

  private func reduceHibernateTab(_ state: inout State, tabID: TerminalTabID) -> Effect<Action> {
    guard var pane = state.layout.pane(containingTab: tabID), let contentID = pane.tabs[id: tabID]?.content.id else {
      return .none
    }
    // Fetch before acting so a missing entry never hibernates without landing
    // its snapshot.
    guard let content = contentRuntime.content(for: contentID) else {
      Self.logger.warning("hibernateTab found no runtime content for \(contentID.rawValue)")
      return .none
    }
    content.hibernate()
    // Land the frozen grid recorded at hibernation in persisted state.
    pane.tabs[id: tabID]?.content = content.snapshot()
    state.layout.panes[id: pane.id] = pane
    return .none
  }

  private func reduceWakeTab(_ state: inout State, tabID: TerminalTabID) -> Effect<Action> {
    guard let pane = state.layout.pane(containingTab: tabID), let snapshot = pane.tabs[id: tabID]?.content else {
      return .none
    }
    let geometry = Self.wakeGeometry(for: snapshot)
    if let content = contentRuntime.content(for: snapshot.id) {
      content.startSession(at: geometry)
      return .none
    }
    // Post-relaunch the runtime is empty; rebuild the content from stored state.
    guard let terminalState = snapshot.state.terminalState else {
      Self.logger.warning("wakeTab has no terminal payload for \(snapshot.id.rawValue)")
      return .none
    }
    let content = layoutContentFactory.make(snapshot.id, terminalState)
    guard contentRuntime.provision(content, at: geometry) else {
      Self.logger.warning("wakeTab provision refused for \(snapshot.id.rawValue)")
      return .none
    }
    return .none
  }

  /// The geometry that reproduces the frozen grid, else the deliberate fallback.
  private static func wakeGeometry(for snapshot: ContentSnapshot) -> ContentGeometry {
    guard let grid = snapshot.state.terminalState?.frozenGrid, let restored = ContentGeometry.restored(grid) else {
      return .fallback
    }
    return restored
  }
}

// MARK: - Panes.

extension LayoutFeature {
  private func reduceSplitPane(
    _ state: inout State,
    anchorID: PaneID,
    direction: SplitTree<PaneID>.NewDirection,
    spec: NewTabSpec
  ) -> Effect<Action> {
    // Validate the anchor before provisioning: a session started for a doomed
    // insert would leak.
    guard state.layout.panes[id: anchorID] != nil else {
      Self.logger.warning("splitPane at unknown anchor \(anchorID.rawValue)")
      return .none
    }
    guard let identity = mintedIdentity(in: state.layout, for: spec, operation: "splitPane") else { return .none }
    guard provisionContent(id: identity.contentID, from: spec, operation: "splitPane") else { return .none }
    let paneID = PaneID(rawValue: uuid())
    do {
      // `inserting` clears zoom by design: the new pane must be visible.
      state.layout.tree = try state.layout.tree.inserting(view: paneID, at: anchorID, direction: direction)
    } catch {
      // Defense in depth behind the anchor pre-check; the tombstone routes the
      // started session into the kill path instead of leaking it.
      contentRuntime.remove(identity.contentID, tombstone: true)
      Self.logger.error("splitPane insert failed at \(anchorID.rawValue): \(error)")
      return .none
    }
    let tab = TabItem(
      id: identity.tabID,
      title: spec.title,
      content: ContentSnapshot(id: identity.contentID, state: .terminal(spec.initialState))
    )
    state.layout.panes.append(Pane(id: paneID, tabs: [tab], selectedTabID: tab.id))
    if spec.select {
      focus(&state, paneID: paneID)
    }
    return .none
  }

  private func reduceClosePane(_ state: inout State, paneID: PaneID) -> Effect<Action> {
    guard let pane = state.layout.panes[id: paneID] else { return .none }
    for tab in pane.tabs {
      contentRuntime.remove(tab.content.id, tombstone: true)
    }
    collapse(&state, paneID: paneID)
    return .none
  }

  private func reduceResizePane(_ state: inout State, node: SplitTree<PaneID>.Node, ratio: Double) -> Effect<Action> {
    // Only split nodes carry a ratio.
    guard case .split = node else { return .none }
    do {
      state.layout.tree = try state.layout.tree.replacing(
        node: node,
        with: node.resizing(to: min(0.9, max(0.1, ratio)))
      )
    } catch {
      Self.logger.warning("resizePane on a node outside the tree")
    }
    return .none
  }

  /// Removes a pane's leaf and the pane, retargeting focus to the neighbor
  /// computed before the removal only when the closed pane held it.
  private func collapse(_ state: inout State, paneID: PaneID) {
    let node = state.layout.tree.find(id: paneID.rawValue)
    if node == nil {
      // Only observable trace of a pane whose leaf already left the tree.
      Self.logger.warning("Collapsing pane \(paneID.rawValue) with no tree leaf.")
    }
    let target = node.flatMap { state.layout.tree.focusTargetAfterClosing($0) }
    if let node {
      state.layout.tree = state.layout.tree.removing(node)
    }
    state.layout.panes.remove(id: paneID)
    let focusSurvives = state.layout.focusedPaneID.flatMap { state.layout.panes[id: $0] } != nil
    guard !focusSurvives else { return }
    let resolvedTarget = target.flatMap { state.layout.panes[id: $0] != nil ? $0 : nil }
    if let newFocus = resolvedTarget ?? state.layout.panes.first?.id {
      focus(&state, paneID: newFocus)
    } else {
      state.layout.focusedPaneID = nil
    }
  }
}

// MARK: - Focus and zoom.

extension LayoutFeature {
  private func reduceFocusPane(_ state: inout State, target: FocusTarget) -> Effect<Action> {
    switch target {
    case .pane(let paneID):
      focus(&state, paneID: paneID)
    case .direction(let direction):
      guard let focusedID = state.layout.focusedPaneID,
        let node = state.layout.tree.find(id: focusedID.rawValue),
        let resolved = state.layout.tree.focusTarget(for: direction, from: node)
      else { break }
      focus(&state, paneID: resolved)
    }
    return .none
  }

  /// Focuses a pane; when focus actually moves while zoomed, the
  /// split-preserve-zoom policy decides whether the zoom follows or clears,
  /// mirroring `gotoSplit`. Re-focusing the current pane never touches zoom.
  private func focus(_ state: inout State, paneID: PaneID) {
    guard state.layout.panes[id: paneID] != nil, state.layout.focusedPaneID != paneID else { return }
    state.layout.focusedPaneID = paneID
    guard state.layout.tree.zoomed != nil else { return }
    guard splitZoomPolicy.preservesZoomOnNavigation(), let node = state.layout.tree.find(id: paneID.rawValue) else {
      state.layout.tree = state.layout.tree.settingZoomed(nil)
      return
    }
    state.layout.tree = state.layout.tree.settingZoomed(node)
  }

  private func reduceToggleZoom(_ state: inout State, paneID: PaneID) -> Effect<Action> {
    // Mirror toggleSplitZoom: zooming a lone leaf is meaningless, and the
    // toggled pane takes focus either way.
    guard state.layout.tree.isSplit, let node = state.layout.tree.find(id: paneID.rawValue) else { return .none }
    state.layout.focusedPaneID = paneID
    state.layout.tree = state.layout.tree.settingZoomed(state.layout.tree.zoomed == node ? nil : node)
    return .none
  }
}

// MARK: - Runtime events.

extension LayoutFeature {
  private func reduceRuntimeEvent(_ state: inout State, event: RuntimeEvent) -> Effect<Action> {
    switch event {
    case .killConfirmed(let contentID):
      contentRuntime.confirmKill(contentID)
    case .titleChanged(let contentID, let title):
      guard let located = state.layout.tab(containingContent: contentID) else { break }
      // TUIs rewrite their title constantly; skip no-op writes so an unchanged
      // title does not re-render the tab strip on every report.
      guard located.tab.title != title else { break }
      var pane = located.pane
      pane.tabs[id: located.tab.id]?.title = title
      state.layout.panes[id: pane.id] = pane
    }
    return .none
  }
}

// MARK: - Shared helpers.

extension LayoutFeature {
  /// Resolves the spec's identities against the layout: a colliding tab ID is
  /// minted around, mirroring `createTab`; a colliding content ID refuses the
  /// action outright, since it names a live session.
  private func mintedIdentity(
    in layout: PaneLayout,
    for spec: NewTabSpec,
    operation: StaticString
  ) -> (tabID: TerminalTabID, contentID: ContentID)? {
    var tabID = spec.tabID ?? TerminalTabID(rawValue: uuid())
    if layout.pane(containingTab: tabID) != nil {
      Self.logger.warning("\(operation): duplicate tab ID \(tabID.rawValue), generating a new one.")
      tabID = TerminalTabID(rawValue: uuid())
    }
    let contentID = spec.contentID ?? ContentID(rawValue: uuid())
    guard layout.tab(containingContent: contentID) == nil else {
      Self.logger.warning("\(operation) refused duplicate content \(contentID.rawValue)")
      return nil
    }
    return (tabID: tabID, contentID: contentID)
  }

  /// Creates and provisions content; false when the runtime refuses
  /// (tombstoned or already registered), dropping the freshly made content
  /// unprovisioned.
  private func provisionContent(
    id contentID: ContentID,
    from spec: NewTabSpec,
    operation: StaticString
  ) -> Bool {
    let content = layoutContentFactory.make(contentID, spec.initialState)
    guard contentRuntime.provision(content, at: spec.geometry) else {
      Self.logger.warning("\(operation) provision refused for content \(contentID.rawValue)")
      return false
    }
    return true
  }
}

extension ContentState {
  /// The terminal payload; the only kind today.
  fileprivate var terminalState: TerminalContentState? {
    switch self {
    case .terminal(let state): state
    }
  }
}
