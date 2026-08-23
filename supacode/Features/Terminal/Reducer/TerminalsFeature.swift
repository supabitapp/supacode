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

  /// How many most-recently-selected worktrees keep their visible tabs live no
  /// matter how long they stay deselected, so flipping back among that set never
  /// pays a rewake.
  static let liveWorktreeLimit = 3

  /// Per-tab cancellation key for the hibernation grace timer.
  nonisolated enum HibernationTimerID: Hashable, Sendable {
    case tab(TabID)
  }

  /// Cancellation key for the process-wide memory-pressure subscription.
  nonisolated enum CancelID: Hashable, Sendable {
    case memoryPressure
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
    /// Most-recently-selected worktrees, newest first, capped at
    /// `liveWorktreeLimit`. Their visible panes' selected tabs never arm a grace
    /// timer, so flipping back among them is instant.
    var recentWorktreeIDs: [Worktree.ID] = []
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
    /// Subscribes the memory-pressure source the hibernation policy reacts to.
    case task
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
    /// The system reported memory pressure: drop the recency budget to the
    /// selection and hibernate the hidden tabs now, skipping the grace window.
    case memoryPressureWarning
  }

  private static let logger = SupaLogger("TerminalsFeature")

  // Ratio drags, the inline rename begin/end toggles, and a teardown title
  // commit never flip tab visibility, so skip the layout-wide re-diff for them.
  private static func canAffectVisibility(_ action: LayoutFeature.Action) -> Bool {
    switch action {
    case .resizePane, .beginTabRename, .endTabRename, .runtime(.titleCommitted):
      return false
    case .newTab, .splitPane, .closeTab, .closePane, .selectTab, .renameTab, .focusPane,
      .moveTab, .moveTabToSplit, .moveTabToSpanningSplit, .enterWindowMode, .exitWindowMode,
      .equalizePanes, .toggleZoom, .hibernateTab, .wakeTab, .runtime(.killConfirmed),
      .contentRequestedClose, .contentRequestedNewTab, .contentRequestedSplit,
      .contentRequestedFocus, .contentRequestedFocusSplit, .contentRequestedToggleZoom,
      .contentRequestedResize, .contentRequestedGotoTab, .contentRequestedMoveTab, .alert:
      return true
    }
  }

  @Dependency(ContentRuntime.self) private var contentRuntime
  @Dependency(LayoutChangeObserver.self) private var layoutChangeObserver
  @Dependency(MemoryPressureClient.self) private var memoryPressure
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

      case .task:
        return .run { [memoryPressure] send in
          for await _ in memoryPressure.warnings() {
            await send(.memoryPressureWarning)
          }
        }
        .cancellable(id: CancelID.memoryPressure, cancelInFlight: true)

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
        state.recentWorktreeIDs.removeAll { $0 == worktreeID }
        return reconcileHibernation(&state)

      case .selectedWorktreeChanged(let worktreeID):
        state.selectedWorktreeID = worktreeID
        Self.recordSelection(worktreeID, in: &state.recentWorktreeIDs)
        return reconcileHibernation(&state)

      case .hibernationPolicyChanged:
        return reconcileHibernation(&state)

      case .hibernationGraceElapsed(let worktreeID, let tabID):
        return reduceHibernationGraceElapsed(&state, worktreeID: worktreeID, tabID: tabID)

      case .memoryPressureWarning:
        return reduceMemoryPressureWarning(&state)

      case .layoutsHydrated(let file):
        state.layoutsAreReadOnly = file.schemaVersion > LayoutsFile.currentSchemaVersion
        // The runtime keys globally by content id and hibernation by tab id, so
        // seed from what is already hydrated and refuse any record that reuses an
        // id from another worktree (possible in pre-creation-gate layouts).
        var seenContentIDs = Set(state.layouts.flatMap { $0.layout.allContentIDs })
        var seenTabIDs = Set(state.layouts.flatMap { $0.layout.panes.flatMap(\.tabs.ids) })
        for (key, record) in file.worktrees.sorted(by: { $0.key < $1.key }) {
          guard record.layout.isConsistent else {
            Self.logger.error("Dropping inconsistent persisted layout for \(key)")
            continue
          }
          let contentIDs = record.layout.allContentIDs
          let tabIDs = record.layout.panes.flatMap(\.tabs.ids)
          guard seenContentIDs.isDisjoint(with: contentIDs), seenTabIDs.isDisjoint(with: tabIDs) else {
            Self.logger.error("Dropping persisted layout for \(key): an id collides with another worktree")
            continue
          }
          let worktreeID = Worktree.ID(key)
          guard state.layouts[id: worktreeID] == nil else { continue }
          state.layouts.append(LayoutFeature.State(id: worktreeID, layout: record.layout))
          seenContentIDs.formUnion(contentIDs)
          seenTabIDs.formUnion(tabIDs)
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

  /// Moves a selection to the front of the recency list, capped at
  /// `liveWorktreeLimit`. Deselecting keeps the list, so the worktree just left
  /// stays the most recent.
  private static func recordSelection(_ worktreeID: Worktree.ID?, in recents: inout [Worktree.ID]) {
    guard let worktreeID else { return }
    recents.removeAll { $0 == worktreeID }
    recents.insert(worktreeID, at: 0)
    if recents.count > liveWorktreeLimit {
      recents.removeLast(recents.count - liveWorktreeLimit)
    }
  }

  /// Whether recency alone keeps this hidden tab live: it is the selected tab of
  /// a visible pane (so stacked background tabs never qualify) and its worktree
  /// is still inside the recency window.
  private static func recencyRetains(
    _ tab: TabItem,
    pane: Pane,
    in layout: LayoutFeature.State,
    visiblePanes: Set<PaneID>,
    recentWorktreeIDs: [Worktree.ID]
  ) -> Bool {
    guard pane.selectedTabID == tab.id, visiblePanes.contains(pane.id) else { return false }
    return recentWorktreeIDs.contains(layout.id)
  }

  /// Diffs the hidden set against armed timers and wakes newly visible
  /// hibernated tabs. Cheap enough to run after every layout action.
  private func reconcileHibernation(_ state: inout State) -> Effect<Action> {
    @Shared(.settingsFile) var settingsFile: SettingsFile
    let enabled = settingsFile.global.terminalHibernationEnabled
    // Tabs that should hold an armed grace timer this pass; anything armed and
    // absent here is cancelled below.
    var keepArmed: Set<TabID> = []
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
            state.wakeRequestedTabs.remove(tab.id)
            // Recency keeps the top worktrees' visible tabs live, so a flip back
            // among them never pays a rewake; they never arm.
            if Self.recencyRetains(
              tab, pane: pane, in: layout,
              visiblePanes: visiblePanes, recentWorktreeIDs: state.recentWorktreeIDs
            ) {
              continue
            }
            // Only a hidden, enabled tab with a live renderer keeps a timer; a
            // hibernated tab (renderer gone) has nothing left to tear down, so
            // it falls out of `keepArmed` and any stale timer is cancelled.
            guard enabled, contentRuntime.content(for: tab.content.id)?.renderer != nil else { continue }
            keepArmed.insert(tab.id)
            if !state.hibernationArmedTabs.contains(tab.id) {
              state.hibernationArmedTabs.insert(tab.id)
              effects.append(armGraceTimer(worktreeID: layout.id, tabID: tab.id))
            }
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
    // Cancel any armed tab no longer eligible: visible, vanished, recency-covered,
    // renderer gone (hibernated), or the flag flipped off.
    for armed in state.hibernationArmedTabs where !keepArmed.contains(armed) {
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
      let tab = pane.tabs[id: tabID]
    else { return .none }
    let visiblePanes = Set(layout.layout.tree.visibleLeaves())
    guard
      Self.isTabHidden(
        tab,
        pane: pane,
        paneShowsContent: Self.paneShowsContent(
          pane,
          in: layout,
          visiblePanes: visiblePanes,
          selectedWorktreeID: state.selectedWorktreeID
        )
      ),
      // Recency can cover a tab after its timer armed; the fire-time gate must
      // agree with the arm-time one or a protected tab still hibernates.
      !Self.recencyRetains(
        tab,
        pane: pane,
        in: layout,
        visiblePanes: visiblePanes,
        recentWorktreeIDs: state.recentWorktreeIDs
      )
    else { return .none }
    guard layout.alert == nil else {
      // A pending close confirmation must keep its target live; re-arm.
      state.hibernationArmedTabs.insert(tabID)
      return armGraceTimer(worktreeID: worktreeID, tabID: tabID)
    }
    let content = contentRuntime.content(for: tab.content.id)
    guard content?.isHibernatable == true else {
      // Nothing left to hibernate (the renderer is already gone, e.g. a
      // concurrent pressure sweep hibernated it after this timer fired): settle
      // instead of re-arming a dead tab into a forever loop.
      guard content?.renderer != nil else {
        state.hibernationDeferralLogged.remove(tabID)
        return .none
      }
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

  /// Under pressure the recency budget is the first thing to go: keep only the
  /// selection live and hibernate every hidden hibernatable tab now instead of
  /// waiting out the grace window. Gated on the hibernation Beta flag.
  private func reduceMemoryPressureWarning(_ state: inout State) -> Effect<Action> {
    @Shared(.settingsFile) var settingsFile: SettingsFile
    guard settingsFile.global.terminalHibernationEnabled else { return .none }
    state.recentWorktreeIDs = state.selectedWorktreeID.map { [$0] } ?? []
    var effects: [Effect<Action>] = []
    for layout in state.layouts {
      // A pending close confirmation keeps its worktree's tabs live; the grace
      // path already exempts it, so the sweep must too.
      guard layout.alert == nil else { continue }
      let visiblePanes = Set(layout.layout.tree.visibleLeaves())
      for pane in layout.layout.panes {
        let showsContent = Self.paneShowsContent(
          pane, in: layout, visiblePanes: visiblePanes, selectedWorktreeID: state.selectedWorktreeID)
        for tab in pane.tabs where Self.isTabHidden(tab, pane: pane, paneShowsContent: showsContent) {
          guard contentRuntime.content(for: tab.content.id)?.isHibernatable == true else { continue }
          // Cancel the pending grace timer and hibernate through the fire-time
          // action, which re-checks visibility just before teardown so a tab the
          // user selects between this sweep and the hibernate is spared.
          if state.hibernationArmedTabs.remove(tab.id) != nil {
            effects.append(.cancel(id: HibernationTimerID.tab(tab.id)))
          }
          state.hibernationDeferralLogged.remove(tab.id)
          effects.append(.send(.hibernationGraceElapsed(worktreeID: layout.id, tabID: tab.id)))
        }
      }
    }
    return effects.isEmpty ? .none : .merge(effects)
  }
}
