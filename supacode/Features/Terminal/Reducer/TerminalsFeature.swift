import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Owns the collection of per-tab `TerminalTabFeature` states. Mirrors the
/// sidebar's `RepositoriesFeature` ownership of `sidebarItems`. Views scope
/// through `store.scope(state: \.terminals, action: \.terminals)` so tab-bar
/// surface area stays bounded to terminal state instead of the whole app.
@Reducer
struct TerminalsFeature {
  /// Bounded recent-removal memory. A late `tabProjectionChanged` emit landing
  /// after `tabRemoved` would otherwise re-insert a phantom tab; tracking the
  /// most recent removals lets the reducer drop those stragglers.
  static let recentlyRemovedTabLimit = 128

  /// Grace window a tab must stay hidden before it hibernates.
  static let hibernationGraceWindow: Duration = .seconds(5 * 60)

  /// Per-tab cancellation key for the hibernation grace timer.
  nonisolated enum HibernationTimerID: Hashable, Sendable {
    case tab(TabID)
  }

  /// Removed-tab record keyed by `(worktreeID, tabID)`. Same-session
  /// snapshot-restore reuses the persisted `tabSnapshot.id`, so scoping the
  /// dedup by worktree lets the FIFO drain when its owning worktree's state
  /// is torn down without shadowing a legitimate re-add.
  struct RecentlyRemovedTab: Equatable, Sendable {
    let worktreeID: Worktree.ID
    let tabID: TabID
  }

  @ObservableState
  struct State: Equatable {
    /// Per-worktree pane and tab topology, hydrated from `layouts.json` v2.
    var layouts: IdentifiedArrayOf<LayoutFeature.State> = []
    /// True when the persisted file was written by a newer schema; its records
    /// are served but must never be written back.
    var layoutsAreReadOnly = false
    /// Per-tab feature instances keyed by `TabID`. Tab-bar leaves
    /// scope through `\.terminalTabs[id:]` for per-tab observation isolation
    /// during agent storms.
    var terminalTabs: IdentifiedArrayOf<TerminalTabFeature.State> = []
    /// FIFO of recently-removed tabs scoped by `(worktreeID, tabID)`. Insert
    /// order = removal order; oldest entry is dropped when the cap is hit.
    var recentlyRemovedTabIDs: [RecentlyRemovedTab] = []
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
    case terminalTabs(IdentifiedActionOf<TerminalTabFeature>)
    /// Worktree selection moved; visibility-driven hibernation re-diffs and
    /// the newly visible selection wakes.
    case selectedWorktreeChanged(Worktree.ID?)
    /// The hibernation Beta flag flipped: enabling re-arms hidden tabs,
    /// disabling cancels every pending timer.
    case hibernationPolicyChanged
    /// A tab's grace timer fired; re-verify and hibernate or re-arm.
    case hibernationGraceElapsed(worktreeID: Worktree.ID, tabID: TabID)
    /// Tab projection arrived from `WorktreeTerminalState`. Inserts a new
    /// per-tab state with its current agent snapshot if missing, then forwards
    /// the projection to the tab's reducer.
    case tabProjectionChanged(
      worktreeID: Worktree.ID,
      projection: WorktreeTabProjection,
      initialAgentSnapshot: AgentPresenceFeature.RowSnapshot
    )
    /// Tab destroyed in the worktree state. Drops the matching feature state.
    case tabRemoved(worktreeID: Worktree.ID, tabID: TabID)
    /// Worktree's entire terminal state was torn down (prune path). Drops any
    /// orphan `terminalTabs` rows and removed-tab FIFO records for this
    /// worktree so a same-session re-attach starts clean.
    case worktreeStateTornDown(worktreeID: Worktree.ID)
  }

  private static let logger = SupaLogger("TerminalsFeature")

  @Dependency(ContentRuntime.self) private var contentRuntime
  @Dependency(\.continuousClock) private var clock

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .layouts:
        // The element reducer already ran; any topology change may flip tab
        // visibility, so re-diff the grace timers.
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
        return .none

      case .terminalTabs:
        return .none

      case .tabProjectionChanged(let worktreeID, let projection, let initialAgentSnapshot):
        let tabID = projection.tabID
        if state.terminalTabs[id: tabID] == nil {
          // Drop stale projections arriving after the tab was removed in this
          // worktree. Matching by (worktreeID, tabID) so a snapshot-restore
          // under a different worktree wouldn't be shadowed; the per-worktree
          // drain on teardown covers the same-worktree restore case.
          guard
            !state.recentlyRemovedTabIDs.contains(where: {
              $0.worktreeID == worktreeID && $0.tabID == tabID
            })
          else { return .none }
          state.terminalTabs.append(
            TerminalTabFeature.State(
              id: tabID,
              worktreeID: worktreeID,
              agentSnapshot: initialAgentSnapshot
            )
          )
        }
        return .send(.terminalTabs(.element(id: tabID, action: .projectionChanged(projection))))

      case .tabRemoved(let worktreeID, let tabID):
        state.terminalTabs.remove(id: tabID)
        state.recentlyRemovedTabIDs.append(
          RecentlyRemovedTab(worktreeID: worktreeID, tabID: tabID)
        )
        if state.recentlyRemovedTabIDs.count > Self.recentlyRemovedTabLimit {
          state.recentlyRemovedTabIDs.removeFirst(
            state.recentlyRemovedTabIDs.count - Self.recentlyRemovedTabLimit
          )
        }
        return .none

      case .worktreeStateTornDown(let worktreeID):
        state.recentlyRemovedTabIDs.removeAll { $0.worktreeID == worktreeID }
        state.terminalTabs.removeAll { $0.worktreeID == worktreeID }
        return .none
      }
    }
    .forEach(\.terminalTabs, action: \.terminalTabs) {
      TerminalTabFeature()
    }
    .forEach(\.layouts, action: \.layouts) {
      LayoutFeature()
    }
  }
}

// MARK: - Hibernation.

extension TerminalsFeature {
  /// Whether a tab is hidden: everything except the selected worktree's
  /// panes' selected tabs.
  private static func isTabHidden(
    _ tab: TabItem,
    pane: Pane,
    worktreeID: Worktree.ID,
    selectedWorktreeID: Worktree.ID?
  ) -> Bool {
    !(worktreeID == selectedWorktreeID && pane.selectedTabID == tab.id)
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
      for pane in layout.layout.panes {
        for tab in pane.tabs {
          allTabs.insert(tab.id)
          let isHidden = Self.isTabHidden(
            tab,
            pane: pane,
            worktreeID: layout.id,
            selectedWorktreeID: state.selectedWorktreeID
          )
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
      Self.isTabHidden(tab, pane: pane, worktreeID: worktreeID, selectedWorktreeID: state.selectedWorktreeID)
    else { return .none }
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
