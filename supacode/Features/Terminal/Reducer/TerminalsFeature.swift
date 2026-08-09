import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// App-shell side effects of a layout change (persistence debounce, sidebar
/// projection, dormant watchers); the integration layer injects the live hook.
nonisolated struct LayoutChangeObserver: Sendable {
  var layoutChanged: @MainActor @Sendable (Worktree.ID) -> Void
}

extension LayoutChangeObserver: DependencyKey {
  static let liveValue = LayoutChangeObserver(layoutChanged: { _ in })
  static let testValue = liveValue
}

/// Owns the per-worktree `LayoutFeature` collection and the visibility-driven
/// hibernation sweep. Views scope through
/// `store.scope(state: \.terminals, action: \.terminals)` so terminal surface
/// area stays bounded to terminal state instead of the whole app.
@Reducer
struct TerminalsFeature {
  /// Grace window a tab must stay hidden before it hibernates.
  static let hibernationGraceWindow: Duration = .seconds(5 * 60)

  /// Per-tab cancellation key for the hibernation grace timer.
  nonisolated enum HibernationTimerID: Hashable, Sendable {
    case tab(TabID)
  }

  @ObservableState
  struct State: Equatable {
    /// Per-worktree pane and tab topology, hydrated from `layouts.json` v2.
    var layouts: IdentifiedArrayOf<LayoutFeature.State> = []
    /// True when the persisted file was written by a newer schema; its records
    /// are served but must never be written back.
    var layoutsAreReadOnly = false
    /// The selected worktree; only its panes' selected tabs are visible, so
    /// everything else is a hibernation candidate.
    var selectedWorktreeID: Worktree.ID?
    /// Tabs with an armed hibernation grace timer.
    var hibernationArmedTabs: Set<TabID> = []
    /// Hidden-but-ineligible tabs already logged, so a permanently ineligible
    /// tab does not spam every grace-window re-fire.
    var hibernationDeferralLogged: Set<TabID> = []
    /// Visible tabs already sent a wake; cleared when the renderer appears or
    /// the tab hides again, so a failed wake cannot loop.
    var wakeRequestedTabs: Set<TabID> = []
  }

  enum Action {
    case layouts(IdentifiedActionOf<LayoutFeature>)
    /// The migrated layouts file finished loading. Consistent records become
    /// `LayoutFeature` states; inconsistent ones fall back to a fresh layout
    /// on first use.
    case layoutsHydrated(LayoutsFile)
    /// Ensures a layout exists for a worktree and carries its display name for
    /// minted tab titles. Never replaces a live layout.
    case attachLayout(worktreeID: Worktree.ID, titlePrefix: String)
    /// Drops a pruned worktree's layout and bookkeeping.
    case detachLayout(worktreeID: Worktree.ID)
    /// Worktree selection moved; visibility-driven hibernation re-diffs and
    /// the newly visible selection wakes.
    case selectedWorktreeChanged(Worktree.ID?)
    /// The hibernation Beta flag flipped: enabling re-arms hidden tabs,
    /// disabling cancels every pending timer.
    case hibernationPolicyChanged
    /// A tab's grace timer fired; re-verify and hibernate or re-arm.
    case hibernationGraceElapsed(worktreeID: Worktree.ID, tabID: TabID)
  }

  private static let logger = SupaLogger("TerminalsFeature")

  // Ratio drags and title reports arrive at high frequency and cannot flip
  // tab visibility; skip the layout-wide re-diff for them.
  private static func canAffectVisibility(_ action: LayoutFeature.Action) -> Bool {
    switch action {
    case .resizePane, .runtime(.titleChanged), .beginTabRename, .endTabRename:
      return false
    case .newTab, .splitPane, .closeTab, .closePane, .selectTab, .renameTab, .focusPane,
      .moveTab, .moveTabToSplit, .enterWindowMode, .exitWindowMode,
      .equalizePanes, .toggleZoom, .hibernateTab, .wakeTab, .runtime(.killConfirmed),
      .contentRequestedClose, .contentRequestedNewTab, .contentRequestedSplit,
      .contentRequestedFocus, .contentRequestedFocusSplit, .contentRequestedToggleZoom,
      .contentRequestedResize, .contentRequestedGotoTab, .contentRequestedMoveTab, .alert:
      return true
    }
  }

  @Dependency(ContentRuntime.self) private var contentRuntime
  @Dependency(LayoutChangeObserver.self) private var layoutChangeObserver
  @Dependency(\.continuousClock) private var clock

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .layouts(.element(let worktreeID, let action)):
        // The element reducer already ran; any topology change may flip tab
        // visibility, so re-diff the grace timers and fire the app-shell
        // hooks (persistence debounce, sidebar projection).
        let hibernation = Self.canAffectVisibility(action) ? reconcileHibernation(&state) : .none
        return .merge(
          hibernation,
          .run { _ in await layoutChangeObserver.layoutChanged(worktreeID) }
        )

      case .layouts:
        return reconcileHibernation(&state)

      case .attachLayout(let worktreeID, let titlePrefix):
        if state.layouts[id: worktreeID] == nil {
          state.layouts.append(LayoutFeature.State(id: worktreeID, layout: PaneLayout()))
        }
        state.layouts[id: worktreeID]?.titlePrefix = titlePrefix
        return .none

      case .detachLayout(let worktreeID):
        // Bookkeeping is NOT pre-cleared: the reconcile below must still see
        // the armed entries to emit their timer cancellations.
        state.layouts.remove(id: worktreeID)
        return reconcileHibernation(&state)

      case .selectedWorktreeChanged(let worktreeID):
        state.selectedWorktreeID = worktreeID
        return reconcileHibernation(&state)

      case .hibernationPolicyChanged:
        return reconcileHibernation(&state)

      case .hibernationGraceElapsed(let worktreeID, let tabID):
        return reduceHibernationGraceElapsed(&state, worktreeID: worktreeID, tabID: tabID)

      case .layoutsHydrated(let file):
        state.layoutsAreReadOnly = file.schemaVersion > LayoutsFile.currentSchemaVersion
        for (key, record) in file.worktrees.sorted(by: { $0.key < $1.key }) {
          guard record.layout.isConsistent else {
            Self.logger.error("Dropping inconsistent persisted layout for \(key)")
            continue
          }
          let worktreeID = Worktree.ID(key)
          guard state.layouts[id: worktreeID] == nil else { continue }
          state.layouts.append(LayoutFeature.State(id: worktreeID, layout: record.layout))
        }
        // Hydration can land after the first selection; re-diff so the
        // restored hidden tabs arm and the visible selection wakes.
        return reconcileHibernation(&state)
      }
    }
    .forEach(\.layouts, action: \.layouts) {
      LayoutFeature()
    }
  }
}

// MARK: - Hibernation.

extension TerminalsFeature {
  /// Whether a tab is hidden: everything except the selected tab of a pane
  /// that shows content somewhere.
  private static func isTabHidden(_ tab: TabItem, pane: Pane, paneShowsContent: Bool) -> Bool {
    !(paneShowsContent && pane.selectedTabID == tab.id)
  }

  /// Whether a pane's area renders: the selected worktree's visible panes
  /// (zoom hides the rest), or any windowed pane, whose window stays open
  /// even when miniaturized.
  private static func paneShowsContent(
    _ pane: Pane,
    in layout: LayoutFeature.State,
    visiblePanes: Set<PaneID>,
    selectedWorktreeID: Worktree.ID?
  ) -> Bool {
    if layout.windowedPaneIDs.contains(pane.id) {
      return true
    }
    return layout.id == selectedWorktreeID && visiblePanes.contains(pane.id)
  }

  /// Diffs the hidden set against armed timers and wakes newly visible
  /// hibernated tabs. Cheap enough to run after every layout action.
  private func reconcileHibernation(_ state: inout State) -> Effect<Action> {
    @Shared(.settingsFile) var settingsFile: SettingsFile
    let enabled = settingsFile.global.terminalHibernationEnabled
    var hidden: Set<TabID> = []
    var allTabs: Set<TabID> = []
    var effects: [Effect<Action>] = []
    for layout in state.layouts {
      let visiblePanes = Set(layout.layout.tree.visibleLeaves())
      for pane in layout.layout.panes {
        let showsContent = Self.paneShowsContent(
          pane,
          in: layout,
          visiblePanes: visiblePanes,
          selectedWorktreeID: state.selectedWorktreeID
        )
        for tab in pane.tabs {
          allTabs.insert(tab.id)
          let isHidden = Self.isTabHidden(tab, pane: pane, paneShowsContent: showsContent)
          if isHidden {
            hidden.insert(tab.id)
            state.wakeRequestedTabs.remove(tab.id)
            guard enabled, !state.hibernationArmedTabs.contains(tab.id) else { continue }
            // Arm only live renderers; hibernated tabs have nothing to tear
            // down and re-arm on wake through this same funnel.
            guard contentRuntime.content(for: tab.content.id)?.renderer != nil else { continue }
            state.hibernationArmedTabs.insert(tab.id)
            effects.append(armGraceTimer(worktreeID: layout.id, tabID: tab.id))
          } else if contentNeedsWake(tab) {
            // The selection landed on a hibernated tab; wake it at its frozen
            // geometry, once per visibility spell so a failed wake can't loop.
            guard !state.wakeRequestedTabs.contains(tab.id) else { continue }
            state.wakeRequestedTabs.insert(tab.id)
            effects.append(.send(.layouts(.element(id: layout.id, action: .wakeTab(id: tab.id)))))
          } else {
            state.wakeRequestedTabs.remove(tab.id)
          }
        }
      }
    }
    // Cancel timers for tabs that became visible, vanished, or lost the flag.
    for armed in state.hibernationArmedTabs where !enabled || !hidden.contains(armed) {
      state.hibernationArmedTabs.remove(armed)
      state.hibernationDeferralLogged.remove(armed)
      effects.append(.cancel(id: HibernationTimerID.tab(armed)))
    }
    state.wakeRequestedTabs.formIntersection(allTabs)
    state.hibernationDeferralLogged.formIntersection(allTabs)
    return effects.isEmpty ? .none : .merge(effects)
  }

  /// True when a visible tab's content has no live renderer to show.
  private func contentNeedsWake(_ tab: TabItem) -> Bool {
    guard let content = contentRuntime.content(for: tab.content.id) else { return true }
    return content.renderer == nil
  }

  private func armGraceTimer(worktreeID: Worktree.ID, tabID: TabID) -> Effect<Action> {
    .run { send in
      try await clock.sleep(for: Self.hibernationGraceWindow)
      await send(.hibernationGraceElapsed(worktreeID: worktreeID, tabID: tabID))
    }
    .cancellable(id: HibernationTimerID.tab(tabID), cancelInFlight: true)
  }

  /// One synchronous turn: re-check hidden and eligible, then hibernate or
  /// re-arm, so a concurrent selection cannot slip a visible tab into
  /// hibernation.
  private func reduceHibernationGraceElapsed(
    _ state: inout State,
    worktreeID: Worktree.ID,
    tabID: TabID
  ) -> Effect<Action> {
    state.hibernationArmedTabs.remove(tabID)
    @Shared(.settingsFile) var settingsFile: SettingsFile
    // Re-check at fire time so a flip to off mid-window never hibernates.
    guard settingsFile.global.terminalHibernationEnabled else { return .none }
    guard let layout = state.layouts[id: worktreeID],
      let pane = layout.layout.pane(containingTab: tabID),
      let tab = pane.tabs[id: tabID],
      Self.isTabHidden(
        tab,
        pane: pane,
        paneShowsContent: Self.paneShowsContent(
          pane,
          in: layout,
          visiblePanes: Set(layout.layout.tree.visibleLeaves()),
          selectedWorktreeID: state.selectedWorktreeID
        )
      )
    else { return .none }
    guard layout.alert == nil else {
      // A pending close confirmation must keep its target live; re-arm.
      state.hibernationArmedTabs.insert(tabID)
      return armGraceTimer(worktreeID: worktreeID, tabID: tabID)
    }
    guard contentRuntime.content(for: tab.content.id)?.isHibernatable == true else {
      // Still hidden but momentarily ineligible; re-arm so a later
      // eligibility flip still hibernates instead of wedging forever.
      if state.hibernationDeferralLogged.insert(tabID).inserted {
        Self.logger.debug("Hibernation for tab \(tabID.rawValue) deferred: not currently eligible; re-armed.")
      }
      state.hibernationArmedTabs.insert(tabID)
      return armGraceTimer(worktreeID: worktreeID, tabID: tabID)
    }
    state.hibernationDeferralLogged.remove(tabID)
    return .send(.layouts(.element(id: worktreeID, action: .hibernateTab(id: tabID))))
  }
}
