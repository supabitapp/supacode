import AppKit
import ComposableArchitecture
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

/// Recipe for a new tab: identity (minted when nil), the kind-keyed content
/// seed, spawn geometry, and whether the tab takes selection and pane focus.
nonisolated struct NewTabSpec: Equatable, Sendable {
  let tabID: TabID?
  let contentID: ContentID?
  let title: String
  /// Tab chrome for producer-styled tabs (blocking scripts).
  let icon: String?
  let tintColor: RepositoryColor?
  let isTitleLocked: Bool
  let content: ContentState
  let geometry: ContentGeometry
  let select: Bool
  /// Source content whose live session seeds inheritable config (cwd, font).
  let inheritedFrom: ContentID?

  init(
    tabID: TabID? = nil,
    contentID: ContentID? = nil,
    title: String,
    icon: String? = nil,
    tintColor: RepositoryColor? = nil,
    isTitleLocked: Bool = false,
    content: ContentState,
    geometry: ContentGeometry,
    select: Bool = true,
    inheritedFrom: ContentID? = nil
  ) {
    self.tabID = tabID
    self.contentID = contentID
    self.title = title
    self.icon = icon
    self.tintColor = tintColor
    self.isTitleLocked = isTitleLocked
    self.content = content
    self.geometry = geometry
    self.select = select
    self.inheritedFrom = inheritedFrom
  }
}

/// Creates live content for a tab; the real surface-backed factory is wired
/// by the integration layer.
nonisolated struct LayoutContentFactory: Sendable {
  var make: @MainActor @Sendable (ContentRequest) -> any TabContent
}

extension LayoutContentFactory: DependencyKey {
  // `unimplemented(_:placeholder:)` cannot mint the id-bound placeholder, so
  // this hand-rolls the same report-and-return contract.
  static let liveValue = LayoutContentFactory(
    make: { request in
      reportIssue("LayoutContentFactory.make is unimplemented")
      return InertTabContent(id: request.contentID, state: request.content)
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

/// Tears down the session behind a closed content (the zmx kill for
/// terminals); the reducer confirms the tombstone when it returns.
nonisolated struct ContentSessionKiller: Sendable {
  var kill: @Sendable (_ content: ContentID, _ worktree: Worktree.ID) async -> Void
}

extension ContentSessionKiller: DependencyKey {
  // The integration layer injects the zmx-backed kill; running unwired must be
  // loud, or closed tabs would confirm tombstones without killing anything.
  static let liveValue = ContentSessionKiller(
    kill: { _, _ in
      reportIssue("ContentSessionKiller.kill is unimplemented")
    }
  )

  static let testValue = liveValue
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

/// Owns one worktree's pane and tab topology: the split tree over panes, each
/// pane's tab strip and selection, focus, and zoom. Content lifecycles go
/// through `ContentRuntime`; state stays value-only.
@Reducer
struct LayoutFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let id: Worktree.ID
    var layout: PaneLayout
    /// Base for minted tab titles ("<prefix> N"); the worktree's name once the
    /// integration layer attaches it.
    var titlePrefix = ""
    /// Bumped whenever a content's renderer identity changes without a layout
    /// change (hibernate, wake), so hosts remount. Never persisted.
    var renderEpoch: UInt64 = 0
    /// The tab whose strip shows the inline rename field; owned here so the
    /// menu command reaches it and it survives structural rebuilds.
    var editingTabID: TabID?
    /// Panes shown in their own windows; the tree keeps their leaves as
    /// placeholders. Never persisted: a relaunch re-attaches them inline.
    var windowedPaneIDs: Set<PaneID> = []
    /// The pane whose close request raised the pending alert, so the host in
    /// that pane's window (main layout or pane window) presents it.
    var alertPaneID: PaneID?
    @Presents var alert: AlertState<Action.Alert>?
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

  /// Which strip position a content-originated goto-tab request aims at,
  /// matching Ghostty's `goto_tab` semantics.
  nonisolated enum TabTarget: Equatable, Sendable {
    case previous
    case next
    case last
    /// One-based position, clamped to the strip.
    case position(Int)
  }

  /// Which of the pane's tabs a content-originated close request covers.
  nonisolated enum CloseScope: Equatable, Sendable {
    case tab
    case otherTabs
    case tabsToTheRight
    case allTabs
  }

  enum Action: Equatable, Sendable {
    case newTab(inPane: PaneID, spec: NewTabSpec)
    case splitPane(id: PaneID, direction: SplitTree<PaneID>.NewDirection, spec: NewTabSpec)
    case closeTab(id: TabID)
    case closePane(id: PaneID)
    case selectTab(id: TabID)
    case renameTab(id: TabID, title: String)
    /// Opens the inline rename field on a tab; locked titles refuse.
    case beginTabRename(id: TabID)
    /// Closes the inline rename field without renaming.
    case endTabRename
    case focusPane(FocusTarget)
    case moveTab(id: TabID, toPane: PaneID, index: Int)
    /// Moves a tab into a brand-new pane split off `anchor`. `select` focuses
    /// the new pane; a background CLI move passes `false` to leave focus put.
    case moveTabToSplit(
      id: TabID, anchor: PaneID, direction: SplitTree<PaneID>.NewDirection, select: Bool = true)
    /// Detaches a pane into its own window; the layout keeps its leaf as a
    /// placeholder.
    case enterWindowMode(paneID: PaneID)
    /// Returns a windowed pane to the layout.
    case exitWindowMode(paneID: PaneID)
    case resizePane(node: SplitTree<PaneID>.Node, ratio: Double)
    case equalizePanes
    case toggleZoom(paneID: PaneID)
    case hibernateTab(id: TabID)
    case wakeTab(id: TabID)
    case runtime(RuntimeEvent)
    /// A content asked to close tabs in its pane; gated by the
    /// confirm-close-tab mode.
    case contentRequestedClose(content: ContentID, scope: CloseScope)
    /// A content asked for a sibling tab in its pane, inheriting its config.
    case contentRequestedNewTab(content: ContentID)
    /// A content asked to split its pane; the new pane opens a fresh tab
    /// inheriting the source's config.
    case contentRequestedSplit(content: ContentID, direction: SplitTree<PaneID>.NewDirection)
    /// A content took input focus; pane focus follows it.
    case contentRequestedFocus(content: ContentID)
    /// A content asked to move focus to a neighboring pane.
    case contentRequestedFocusSplit(content: ContentID, direction: SplitTree<PaneID>.FocusDirection)
    case contentRequestedToggleZoom(content: ContentID)
    /// A content asked to grow its pane by `amount` pixels toward `direction`.
    case contentRequestedResize(content: ContentID, direction: SplitTree<PaneID>.SpatialDirection, amount: UInt16)
    case contentRequestedGotoTab(content: ContentID, target: TabTarget)
    /// A content asked to reorder its tab by `amount` strip positions,
    /// wrapping at the ends.
    case contentRequestedMoveTab(content: ContentID, amount: Int)
    case alert(PresentationAction<Alert>)

    nonisolated enum Alert: Equatable, Sendable {
      case confirmClose(tabs: [TabID])
    }
  }

  private static let logger = SupaLogger("LayoutFeature")

  // Ratio drags and title reports arrive at frame rate and cannot alter
  // structure; exempt them from the per-action layout walk.
  private static func isExemptFromConsistencyCheck(_ action: Action) -> Bool {
    switch action {
    case .resizePane, .runtime(.titleChanged), .beginTabRename, .endTabRename:
      return true
    case .newTab, .splitPane, .closeTab, .closePane, .selectTab, .renameTab, .focusPane,
      .moveTab, .moveTabToSplit, .enterWindowMode, .exitWindowMode,
      .equalizePanes, .toggleZoom, .hibernateTab, .wakeTab, .runtime(.killConfirmed),
      .contentRequestedClose, .contentRequestedNewTab, .contentRequestedSplit,
      .contentRequestedFocus, .contentRequestedFocusSplit, .contentRequestedToggleZoom,
      .contentRequestedResize, .contentRequestedGotoTab, .contentRequestedMoveTab, .alert:
      return false
    }
  }

  @Dependency(ContentRuntime.self) private var contentRuntime
  @Dependency(ContentSessionKiller.self) private var sessionKiller
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
      case .beginTabRename(let tabID):
        guard let tab = state.layout.pane(containingTab: tabID)?.tabs[id: tabID], !tab.isTitleLocked else {
          return .none
        }
        state.editingTabID = tabID
        return .none
      case .endTabRename:
        state.editingTabID = nil
        return .none
      case .focusPane(let target):
        return reduceFocusPane(&state, target: target)
      case .moveTab(let tabID, let targetPaneID, let index):
        return reduceMoveTab(&state, tabID: tabID, targetPaneID: targetPaneID, index: index)
      case .moveTabToSplit(let tabID, let anchorID, let direction, let select):
        return reduceMoveTabToSplit(
          &state, tabID: tabID, anchorID: anchorID, direction: direction, select: select)
      case .enterWindowMode(let paneID):
        return reduceEnterWindowMode(&state, paneID: paneID)
      case .exitWindowMode(let paneID):
        state.windowedPaneIDs.remove(paneID)
        cancelAlert(&state, ifOwnedBy: paneID)
        return .none
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
      case .contentRequestedClose(let contentID, let scope):
        return reduceContentRequestedClose(&state, contentID: contentID, scope: scope)
      case .contentRequestedNewTab(let contentID):
        return reduceContentRequestedNewTab(&state, contentID: contentID)
      case .contentRequestedSplit(let contentID, let direction):
        return reduceContentRequestedSplit(&state, contentID: contentID, direction: direction)
      case .contentRequestedFocus(let contentID):
        guard let located = state.layout.tab(containingContent: contentID) else { return .none }
        focus(&state, paneID: located.pane.id)
        return .none
      case .contentRequestedFocusSplit(let contentID, let direction):
        guard let located = state.layout.tab(containingContent: contentID) else { return .none }
        // A pane window has no neighbors; walking the main tree from its
        // placeholder would strand focus on a window that is not key.
        guard !state.windowedPaneIDs.contains(located.pane.id) else {
          Self.logger.info("focusSplit refused: pane \(located.pane.id.rawValue) is windowed")
          return .none
        }
        focus(&state, paneID: located.pane.id)
        return reduceFocusPane(&state, target: .direction(direction))
      case .contentRequestedToggleZoom(let contentID):
        guard let located = state.layout.tab(containingContent: contentID) else { return .none }
        return reduceToggleZoom(&state, paneID: located.pane.id)
      case .contentRequestedResize(let contentID, let direction, let amount):
        return reduceContentRequestedResize(&state, contentID: contentID, direction: direction, amount: amount)
      case .contentRequestedGotoTab(let contentID, let target):
        return reduceContentRequestedGotoTab(&state, contentID: contentID, target: target)
      case .contentRequestedMoveTab(let contentID, let amount):
        return reduceContentRequestedMoveTab(&state, contentID: contentID, amount: amount)
      case .alert(.presented(.confirmClose(let tabIDs))):
        state.alertPaneID = nil
        return closeTabs(&state, tabIDs: tabIDs)
      case .alert:
        state.alertPaneID = nil
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
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
    let request = ContentRequest(
      worktreeID: state.id,
      tabID: identity.tabID,
      contentID: identity.contentID,
      content: spec.content,
      origin: bootstraps ? .first : .tab,
      inheritedFrom: spec.inheritedFrom
    )
    guard provisionContent(request, at: spec.geometry, operation: "newTab") else { return .none }
    if bootstraps {
      state.layout.tree = SplitTree(view: paneID)
      state.layout.panes.append(Pane(id: paneID))
    }
    guard var pane = state.layout.panes[id: paneID] else {
      // Unreachable behind the guards above; reap the started session anyway.
      return reap(identity.contentID, worktree: state.id)
    }
    let tab = TabItem(
      id: identity.tabID,
      title: spec.title,
      icon: spec.icon,
      tintColor: spec.tintColor,
      content: ContentSnapshot(id: identity.contentID, state: spec.content),
      isTitleLocked: spec.isTitleLocked
    )
    // Insert after the selection;
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

  /// A content-originated close request: resolve the scope's tabs, then close
  /// directly or raise the confirmation, per the confirm-close-tab mode and
  /// each target's busy state.
  private func reduceContentRequestedClose(
    _ state: inout State,
    contentID: ContentID,
    scope: CloseScope
  ) -> Effect<Action> {
    guard let located = state.layout.tab(containingContent: contentID) else { return .none }
    let pane = located.pane
    let targets: [TabID] =
      switch scope {
      case .tab:
        [located.tab.id]
      case .otherTabs:
        pane.tabs.ids.filter { $0 != located.tab.id }
      case .tabsToTheRight:
        pane.tabs.index(id: located.tab.id).map { pane.tabs.dropFirst($0 + 1).map(\.id) } ?? []
      case .allTabs:
        Array(pane.tabs.ids)
      }
    guard !targets.isEmpty else { return .none }
    let interrupts = targets.contains { closeWouldInterrupt(pane.tabs[id: $0]?.content) }
    @Shared(.settingsFile) var settingsFile: SettingsFile
    let confirms: Bool =
      switch settingsFile.global.confirmCloseTab {
      case .always: true
      case .never: false
      case .busy: interrupts
      }
    guard confirms else { return closeTabs(&state, tabIDs: targets) }
    if let pending = state.alertPaneID, pending != pane.id {
      Self.logger.warning("Replacing pane \(pending.rawValue)'s pending close confirmation.")
    }
    state.alertPaneID = pane.id
    state.alert = Self.closeConfirmationAlert(tabs: targets, interrupts: interrupts)
    return .none
  }

  /// Whether closing this content now would interrupt real work: live and
  /// busy, or a terminal with no live renderer, whose zmx session may still
  /// host a process nothing can ask about.
  private func closeWouldInterrupt(_ snapshot: ContentSnapshot?) -> Bool {
    guard let snapshot else { return false }
    guard let content = contentRuntime.content(for: snapshot.id) else {
      return snapshot.kind == .terminal
    }
    if content.isBusy { return true }
    return content.kind == .terminal && content.renderer == nil
  }

  private static func closeConfirmationAlert(tabs targets: [TabID], interrupts: Bool) -> AlertState<Action.Alert> {
    AlertState {
      TextState(targets.count == 1 ? "Close Tab?" : "Close \(targets.count) Tabs?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmClose(tabs: targets)) {
        TextState("Close")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState(Self.closeConfirmationMessage(count: targets.count, interrupts: interrupts))
    }
  }

  private static func closeConfirmationMessage(count: Int, interrupts: Bool) -> String {
    switch (interrupts, count == 1) {
    case (true, true): "This tab has work that closing would interrupt."
    case (true, false): "These tabs have work that closing would interrupt."
    case (false, true): "Closing will end this tab's session."
    case (false, false): "Closing will end these tabs' sessions."
    }
  }

  /// Closes every listed tab that still exists; the per-tab close guards make
  /// vanished ones no-ops.
  private func closeTabs(_ state: inout State, tabIDs: [TabID]) -> Effect<Action> {
    .merge(tabIDs.map { reduceCloseTab(&state, tabID: $0) })
  }

  private func reduceContentRequestedNewTab(_ state: inout State, contentID: ContentID) -> Effect<Action> {
    guard let located = state.layout.tab(containingContent: contentID) else { return .none }
    let spec = NewTabSpec(
      title: nextMintedTitle(in: state),
      content: located.tab.content.state.freshSeed,
      geometry: contentRuntime.spawnGeometry(near: contentID, fallback: focusedContentID(in: state)),
      inheritedFrom: contentID
    )
    return reduceNewTab(&state, paneID: located.pane.id, spec: spec)
  }

  /// The focused pane's visible content, the deterministic geometry fallback
  /// when a request's source is unmounted.
  private func focusedContentID(in state: State) -> ContentID? {
    state.layout.focusedPaneID
      .flatMap { state.layout.panes[id: $0]?.selectedTab?.content.id }
  }

  private func reduceContentRequestedGotoTab(
    _ state: inout State,
    contentID: ContentID,
    target: TabTarget
  ) -> Effect<Action> {
    guard let located = state.layout.tab(containingContent: contentID) else { return .none }
    let tabs = located.pane.tabs
    guard !tabs.isEmpty else { return .none }
    let selectedIndex = located.pane.selectedTabID.flatMap { tabs.index(id: $0) } ?? 0
    let targetIndex: Int
    switch target {
    case .previous:
      targetIndex = (selectedIndex - 1 + tabs.count) % tabs.count
    case .next:
      targetIndex = (selectedIndex + 1) % tabs.count
    case .last:
      targetIndex = tabs.count - 1
    case .position(let position):
      guard position >= 1 else { return .none }
      targetIndex = min(position - 1, tabs.count - 1)
    }
    return reduceSelectTab(&state, tabID: tabs[targetIndex].id)
  }

  private func reduceContentRequestedMoveTab(
    _ state: inout State,
    contentID: ContentID,
    amount: Int
  ) -> Effect<Action> {
    guard let located = state.layout.tab(containingContent: contentID) else { return .none }
    let pane = located.pane
    // Only the selected tab may reorder, so a keybind from a background tab
    // cannot shuffle tabs off-screen.
    guard pane.selectedTabID == located.tab.id, pane.tabs.count > 1 else { return .none }
    guard let index = pane.tabs.index(id: located.tab.id) else { return .none }
    let count = pane.tabs.count
    // Reduce modulo first: the raw amount is config-controlled and unbounded.
    let offset = ((amount % count) + count) % count
    guard offset != 0 else { return .none }
    return reduceMoveTab(&state, tabID: located.tab.id, targetPaneID: pane.id, index: (index + offset) % count)
  }

  /// Next "<prefix> N" title, scanning every pane's strip for the highest
  /// minted index, mirroring the tab manager's numbering.
  private func nextMintedTitle(in state: State) -> String {
    let prefix = state.titlePrefix.isEmpty ? "Terminal" : state.titlePrefix
    var maxIndex = 0
    for pane in state.layout.panes {
      for tab in pane.tabs {
        guard tab.title.hasPrefix("\(prefix) "), let value = Int(tab.title.dropFirst(prefix.count + 1)) else {
          continue
        }
        maxIndex = max(maxIndex, value)
      }
    }
    return "\(prefix) \(maxIndex + 1)"
  }

  private func reduceCloseTab(_ state: inout State, tabID: TabID) -> Effect<Action> {
    guard var pane = state.layout.pane(containingTab: tabID), let index = pane.tabs.index(id: tabID) else {
      return .none
    }
    let reaping = reap(pane.tabs[index].content.id, worktree: state.id)
    releaseTabBookkeeping(&state, tabID: tabID)
    pane.tabs.remove(at: index)
    guard !pane.tabs.isEmpty else {
      collapse(&state, paneID: pane.id)
      return reaping
    }
    if pane.selectedTabID == tabID {
      // Selection retargets to the previous tab, else the first.
      pane.selectedTabID = index > 0 ? pane.tabs[index - 1].id : pane.tabs.first?.id
    }
    state.layout.panes[id: pane.id] = pane
    return reaping
  }

  private func reduceMoveTab(
    _ state: inout State,
    tabID: TabID,
    targetPaneID: PaneID,
    index: Int,
    focusing: Bool = true
  ) -> Effect<Action> {
    guard var source = state.layout.pane(containingTab: tabID), let sourceIndex = source.tabs.index(id: tabID) else {
      return .none
    }
    if source.id == targetPaneID {
      let tab = source.tabs.remove(at: sourceIndex)
      source.tabs.insert(tab, at: min(max(index, 0), source.tabs.count))
      // Reordering deliberately selects the dragged tab, unlike a keyboard
      // move.
      source.selectedTabID = tab.id
      state.layout.panes[id: source.id] = source
      if focusing { focus(&state, paneID: source.id) }
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
    if focusing { focus(&state, paneID: targetPaneID) }
    return .none
  }

  /// Moves an existing tab into a brand-new pane split off the anchor,
  /// collapsing the source pane when the move empties it.
  private func reduceMoveTabToSplit(
    _ state: inout State,
    tabID: TabID,
    anchorID: PaneID,
    direction: SplitTree<PaneID>.NewDirection,
    select: Bool
  ) -> Effect<Action> {
    guard let source = state.layout.pane(containingTab: tabID) else { return .none }
    guard state.layout.panes[id: anchorID] != nil else {
      Self.logger.warning("moveTabToSplit at unknown anchor \(anchorID.rawValue)")
      return .none
    }
    // A windowed anchor renders a placeholder; nothing can drop on it.
    guard !state.windowedPaneIDs.contains(anchorID) else {
      Self.logger.info("moveTabToSplit refused: anchor \(anchorID.rawValue) is windowed")
      return .none
    }
    // Splitting a pane off its own only tab would recreate the same layout.
    guard source.id != anchorID || source.tabs.count > 1 else { return .none }
    let paneID = PaneID(rawValue: uuid())
    do {
      state.layout.tree = try state.layout.tree.inserting(view: paneID, at: anchorID, direction: direction)
    } catch {
      Self.logger.error("moveTabToSplit insert failed at \(anchorID.rawValue): \(error)")
      return .none
    }
    // The new pane starts empty; the ordinary move fills it, retargets the
    // source selection, and collapses the source when it empties.
    state.layout.panes.append(Pane(id: paneID))
    return reduceMoveTab(&state, tabID: tabID, targetPaneID: paneID, index: 0, focusing: select)
  }

  private func reduceSelectTab(_ state: inout State, tabID: TabID) -> Effect<Action> {
    guard var pane = state.layout.pane(containingTab: tabID) else { return .none }
    pane.selectedTabID = tabID
    state.layout.panes[id: pane.id] = pane
    focus(&state, paneID: pane.id)
    return .none
  }

  private func reduceRenameTab(_ state: inout State, tabID: TabID, title: String) -> Effect<Action> {
    guard var pane = state.layout.pane(containingTab: tabID) else { return .none }
    // A script tab owns its title.
    guard pane.tabs[id: tabID]?.isTitleLocked != true else { return .none }
    // Empty rename clears the override on every commit path.
    pane.tabs[id: tabID]?.customTitle = TabItem.normalizedCustomTitle(title)
    state.layout.panes[id: pane.id] = pane
    return .none
  }

  private func reduceHibernateTab(_ state: inout State, tabID: TabID) -> Effect<Action> {
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
    state.renderEpoch &+= 1
    return .none
  }

  private func reduceWakeTab(_ state: inout State, tabID: TabID) -> Effect<Action> {
    guard let pane = state.layout.pane(containingTab: tabID), let snapshot = pane.tabs[id: tabID]?.content else {
      return .none
    }
    let geometry = Self.wakeGeometry(for: snapshot)
    if let content = contentRuntime.content(for: snapshot.id) {
      content.startSession(at: geometry)
      landWokenSnapshot(&state, tabID: tabID, content: content)
      state.renderEpoch &+= 1
      return .none
    }
    // Post-relaunch the runtime is empty; rebuild the content from stored
    // state, whatever its kind.
    let content = layoutContentFactory.make(
      ContentRequest(
        worktreeID: state.id,
        tabID: tabID,
        contentID: snapshot.id,
        content: snapshot.state,
        origin: .restored,
        inheritedFrom: nil
      )
    )
    guard contentRuntime.provision(content, at: geometry) else {
      Self.logger.warning("wakeTab provision refused for \(snapshot.id.rawValue)")
      return .none
    }
    landWokenSnapshot(&state, tabID: tabID, content: content)
    state.renderEpoch &+= 1
    return .none
  }

  /// Refreshes the tab's stored snapshot from the now-live content so a wake
  /// that reflowed the grid persists the fresher one, mirroring hibernate.
  private func landWokenSnapshot(_ state: inout State, tabID: TabID, content: any TabContent) {
    guard let paneID = state.layout.pane(containingTab: tabID)?.id else { return }
    state.layout.panes[id: paneID]?.tabs[id: tabID]?.content = content.snapshot()
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
    // A windowed pane's keybinds must not grow the main layout behind its
    // placeholder.
    guard !state.windowedPaneIDs.contains(anchorID) else {
      Self.logger.info("splitPane refused: anchor \(anchorID.rawValue) is windowed")
      return .none
    }
    guard let identity = mintedIdentity(in: state.layout, for: spec, operation: "splitPane") else { return .none }
    let request = ContentRequest(
      worktreeID: state.id,
      tabID: identity.tabID,
      contentID: identity.contentID,
      content: spec.content,
      origin: .split,
      inheritedFrom: spec.inheritedFrom
    )
    guard provisionContent(request, at: spec.geometry, operation: "splitPane") else { return .none }
    let paneID = PaneID(rawValue: uuid())
    do {
      // `inserting` clears zoom by design: the new pane must be visible.
      state.layout.tree = try state.layout.tree.inserting(view: paneID, at: anchorID, direction: direction)
    } catch {
      // Defense in depth behind the anchor pre-check; reaping routes the
      // started session into the kill path instead of leaking it.
      Self.logger.error("splitPane insert failed at \(anchorID.rawValue): \(error)")
      return reap(identity.contentID, worktree: state.id)
    }
    let tab = TabItem(
      id: identity.tabID,
      title: spec.title,
      icon: spec.icon,
      tintColor: spec.tintColor,
      content: ContentSnapshot(id: identity.contentID, state: spec.content),
      isTitleLocked: spec.isTitleLocked
    )
    state.layout.panes.append(Pane(id: paneID, tabs: [tab], selectedTabID: tab.id))
    if spec.select {
      focus(&state, paneID: paneID)
    }
    return .none
  }

  /// Enters window mode for a pane: its leaf stays in the tree as a
  /// placeholder while the pane renders in its own window.
  private func reduceEnterWindowMode(_ state: inout State, paneID: PaneID) -> Effect<Action> {
    guard state.layout.panes[id: paneID] != nil else { return .none }
    // A zoomed placeholder would fill the whole layout with no content.
    if case .leaf(let leaf) = state.layout.tree.zoomed, leaf == paneID {
      state.layout.tree = state.layout.tree.settingZoomed(nil)
    }
    state.windowedPaneIDs.insert(paneID)
    cancelAlert(&state, ifOwnedBy: paneID)
    return .none
  }

  /// The pane's alert host lives in whichever window shows the pane; a
  /// window-mode flip swaps that host, so a pending confirmation would
  /// survive unpresented and re-materialize as a phantom.
  private func cancelAlert(_ state: inout State, ifOwnedBy paneID: PaneID) {
    guard state.alertPaneID == paneID, state.alert != nil else { return }
    Self.logger.info("Cancelling the pending close confirmation for pane \(paneID.rawValue).")
    state.alert = nil
    state.alertPaneID = nil
  }

  private func reduceContentRequestedSplit(
    _ state: inout State,
    contentID: ContentID,
    direction: SplitTree<PaneID>.NewDirection
  ) -> Effect<Action> {
    guard let located = state.layout.tab(containingContent: contentID) else { return .none }
    let spec = NewTabSpec(
      title: nextMintedTitle(in: state),
      content: located.tab.content.state.freshSeed,
      geometry: contentRuntime.spawnGeometry(near: contentID, fallback: focusedContentID(in: state)),
      inheritedFrom: contentID
    )
    return reduceSplitPane(&state, anchorID: located.pane.id, direction: direction, spec: spec)
  }

  /// Grows the content's pane by `amount` pixels. Mirrors the legacy resize
  /// binding, including its side effect of clearing any zoom.
  private func reduceContentRequestedResize(
    _ state: inout State,
    contentID: ContentID,
    direction: SplitTree<PaneID>.SpatialDirection,
    amount: UInt16
  ) -> Effect<Action> {
    guard let located = state.layout.tab(containingContent: contentID),
      let node = state.layout.tree.find(id: located.pane.id.rawValue)
    else { return .none }
    // A pane window has no dividers to drag.
    guard !state.windowedPaneIDs.contains(located.pane.id) else {
      Self.logger.info("resize refused: pane \(located.pane.id.rawValue) is windowed")
      return .none
    }
    // Pane extents come from each pane's visible renderer; a pane mid-wake
    // reports zero, and a degenerate total would slam ratios to the clamp.
    // A windowed pane's renderer sizes its own window, not its placeholder,
    // so it must not feed main-tree geometry; the total then under-reports
    // the placeholder's area, an accepted approximation.
    let panes = state.layout.panes
    let windowedPaneIDs = state.windowedPaneIDs
    let size = state.layout.tree.viewBounds { paneID in
      guard !windowedPaneIDs.contains(paneID), let selected = panes[id: paneID]?.selectedTab else { return .zero }
      return contentRuntime.renderer(for: selected.content.id)?.bounds.size ?? .zero
    }
    guard size.width >= 1, size.height >= 1 else {
      Self.logger.info("resize skipped: pane extents are degenerate.")
      return .none
    }
    do {
      state.layout.tree = try state.layout.tree.resizing(
        node: node,
        by: amount,
        in: direction,
        with: CGRect(origin: .zero, size: size)
      )
    } catch {
      Self.logger.warning("contentRequestedResize found no resizable split for \(contentID.rawValue)")
    }
    return .none
  }

  private func reduceClosePane(_ state: inout State, paneID: PaneID) -> Effect<Action> {
    guard let pane = state.layout.panes[id: paneID] else { return .none }
    // Merged: one hung kill must not queue the siblings behind it.
    let reaping = Effect<Action>.merge(pane.tabs.map { reap($0.content.id, worktree: state.id) })
    for tab in pane.tabs {
      releaseTabBookkeeping(&state, tabID: tab.id)
    }
    collapse(&state, paneID: paneID)
    return reaping
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

  /// Drops a closing tab's transient per-tab state.
  private func releaseTabBookkeeping(_ state: inout State, tabID: TabID) {
    if state.editingTabID == tabID {
      state.editingTabID = nil
    }
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
    state.windowedPaneIDs.remove(paneID)
    // The alert host unmounts with the last pane; a surviving alert would
    // re-present as a phantom on the next mount.
    if state.layout.panes.isEmpty {
      state.alert = nil
      state.alertPaneID = nil
    }
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
        var node = state.layout.tree.find(id: focusedID.rawValue)
      else { break }
      // Windowed leaves are placeholders; walk past them so a windowed
      // neighbor never becomes an absorbing wall. Bounded by the leaf count.
      for _ in 0..<state.layout.panes.count {
        guard let resolved = state.layout.tree.focusTarget(for: direction, from: node) else { break }
        guard state.windowedPaneIDs.contains(resolved) else {
          focus(&state, paneID: resolved)
          break
        }
        guard let next = state.layout.tree.find(id: resolved.rawValue) else { break }
        node = next
      }
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
    // Focusing a windowed pane happens in its own window; the main tree's
    // zoom must neither follow onto the placeholder nor clear.
    guard !state.windowedPaneIDs.contains(paneID) else { return }
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
    // Zooming a windowed pane would fill the layout with its placeholder.
    guard !state.windowedPaneIDs.contains(paneID) else {
      Self.logger.info("toggleZoom refused: pane \(paneID.rawValue) is windowed")
      return .none
    }
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
      // A script tab owns its title; shell reports must not overwrite it.
      guard !located.tab.isTitleLocked else { break }
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
  ) -> (tabID: TabID, contentID: ContentID)? {
    var tabID = spec.tabID ?? TabID(rawValue: uuid())
    if layout.pane(containingTab: tabID) != nil {
      Self.logger.warning("\(operation): duplicate tab ID \(tabID.rawValue), generating a new one.")
      tabID = TabID(rawValue: uuid())
    }
    let contentID = spec.contentID ?? ContentID(rawValue: uuid())
    guard layout.tab(containingContent: contentID) == nil else {
      Self.logger.warning("\(operation) refused duplicate content \(contentID.rawValue)")
      return nil
    }
    return (tabID: tabID, contentID: contentID)
  }

  /// Tombstones a content and returns the effect that kills its session and
  /// confirms the tombstone. The kill runs unstructured so element teardown
  /// cannot abandon a half-killed session; a cancelled effect confirms the
  /// tombstone straight on the runtime instead of leaving it stale.
  private func reap(_ contentID: ContentID, worktree worktreeID: Worktree.ID) -> Effect<Action> {
    contentRuntime.remove(contentID, tombstone: true)
    return .run { [contentRuntime, sessionKiller] send in
      let kill = Task { await sessionKiller.kill(contentID, worktreeID) }
      await kill.value
      // Confirm straight on the runtime: a layout detached mid-kill (prune)
      // would drop the action below and leak the tombstone forever.
      await contentRuntime.confirmKill(contentID)
      guard !Task.isCancelled else { return }
      await send(.runtime(.killConfirmed(id: contentID)))
    }
  }

  /// Creates and provisions content; false when the runtime refuses
  /// (tombstoned or already registered), dropping the freshly made content
  /// unprovisioned.
  private func provisionContent(
    _ request: ContentRequest,
    at geometry: ContentGeometry,
    operation: StaticString
  ) -> Bool {
    let content = layoutContentFactory.make(request)
    guard contentRuntime.provision(content, at: geometry) else {
      Self.logger.warning("\(operation) provision refused for content \(request.contentID.rawValue)")
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
