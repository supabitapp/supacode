import ComposableArchitecture
import Dependencies
import Foundation
import OrderedCollections
import SupacodeSettingsShared

/// Dependency switch that gates the reducer's post-reduce sidebar-structure
/// recompute. Defaults `true` everywhere so production, preview, and tests
/// see the same cached structure. See `AGENTS.md` (Sidebar performance) for
/// the canonical TestStore mirror rules.
public nonisolated enum SidebarStructureAutoRecomputeKey: DependencyKey {
  public static let liveValue: Bool = true
  public static let previewValue: Bool = true
  public static let testValue: Bool = true
}

extension DependencyValues {
  public nonisolated var sidebarStructureAutoRecompute: Bool {
    get { self[SidebarStructureAutoRecomputeKey.self] }
    set { self[SidebarStructureAutoRecomputeKey.self] = newValue }
  }
}

/// Classification buckets for the global Active section. Membership only:
/// a non-nil classification means the row belongs in Active (ordering is
/// alphabetical, see `SidebarHighlightOrdering`). Rows that don't classify
/// are excluded from Active but still appear in Pinned. Cases are ordered by
/// severity; `classify` returns the most severe that matches (errored first).
enum SidebarActiveClassification: Int, CaseIterable, Comparable, Sendable {
  /// An agent stopped on an error.
  case errored = 0
  case unreadAwaitingRunning = 1
  case unreadAwaiting = 2
  case unreadAgentRunning = 3
  case unreadAgent = 4
  case unreadRunning = 5
  case awaitingRunning = 6
  case awaiting = 7
  case agentRunning = 8
  case agent = 9
  case running = 10

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  /// Pure classifier driven by four leaf-local flags. Returns `nil` for rows
  /// that don't belong in Active (no unread, no awaiting, no agent, no script).
  static func classify(
    hasUnread: Bool,
    hasAwaiting: Bool,
    hasAgent: Bool,
    hasRunning: Bool
  ) -> Self? {
    if hasUnread && hasAwaiting && hasRunning { return .unreadAwaitingRunning }
    if hasUnread && hasAwaiting { return .unreadAwaiting }
    if hasUnread && hasAgent && hasRunning { return .unreadAgentRunning }
    if hasUnread && hasAgent { return .unreadAgent }
    if hasUnread && hasRunning { return .unreadRunning }
    if hasAwaiting && hasRunning { return .awaitingRunning }
    if hasAwaiting { return .awaiting }
    if hasAgent && hasRunning { return .agentRunning }
    if hasAgent { return .agent }
    if hasRunning { return .running }
    return nil
  }

  /// `hasAgent` is keyed off agent badge presence (any tracked instance,
  /// including `.idle`) so a row with a visible agent badge surfaces in
  /// Active even when the agent isn't actively working; `state.agents` is
  /// already empty when badges are disabled by the user.
  static func classify(_ state: SidebarItemFeature.State) -> Self? {
    // Error wins the classification when a row also has other Active signals.
    if state.hasAgentError { return .errored }
    return classify(
      hasUnread: state.hasUnseenNotifications,
      hasAwaiting: state.hasAgentAwaitingInput,
      hasAgent: !state.agents.isEmpty,
      hasRunning: !state.runningScripts.isEmpty
    )
  }
}

/// Pure ordering layer behind the highlight aggregator. Alphabetical
/// (case-insensitive) by branch name, with unread rows floated to the top
/// when `prioritizeNotified` is set. Classification only gates membership:
/// Active drops unclassified rows, Pinned keeps them. `id` is the final
/// tie-break so rows sharing a branch name across repos keep a deterministic
/// order (the sort is otherwise unstable).
enum SidebarHighlightOrdering {
  struct Candidate: Equatable, Sendable {
    let id: SidebarItemID
    let branchName: String
    let isNotified: Bool
    let classification: SidebarActiveClassification?
  }

  static func orderedRowIDs(
    forPinned: Bool,
    prioritizeNotified: Bool,
    candidates: [Candidate]
  ) -> [SidebarItemID] {
    let included = forPinned ? candidates : candidates.filter { $0.classification != nil }
    return
      included
      .sorted { lhs, rhs in
        if prioritizeNotified, lhs.isNotified != rhs.isNotified {
          return lhs.isNotified
        }
        return branchNameOrdersBefore(lhs.branchName, id: lhs.id, rhs.branchName, id: rhs.id)
      }
      .map(\.id)
  }

  /// Case-insensitive branch-name order with `id` as the deterministic final
  /// tie-break (the sort is otherwise unstable, so equal names could flip).
  static func branchNameOrdersBefore(
    _ lhsName: String,
    id lhsID: SidebarItemID,
    _ rhsName: String,
    id rhsID: SidebarItemID
  ) -> Bool {
    switch lhsName.localizedCaseInsensitiveCompare(rhsName) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame: return lhsID.rawValue < rhsID.rawValue
    }
  }
}

/// Per-repo render plan precomputed by the reducer. Lives here, not in a view
/// file, so the per-repo slot partition / hoisted-row filter / dedupe is a
/// reducer-state derivation (per the "view does zero computation" contract).
struct SidebarItemGroup: Identifiable, Equatable, Sendable {
  enum MoveBehavior: Hashable, Sendable {
    case disabled
    case pinned(Repository.ID)
    case unpinned(Repository.ID)
  }

  enum Slot: Hashable, Sendable {
    case main(isSole: Bool)
    case pinnedTail
    case pending
    case unpinnedTail
  }

  let slot: Slot
  let repositoryID: Repository.ID
  let rowIDs: [SidebarItemID]

  var id: Slot { slot }

  var hideSubtitle: Bool {
    if case .main(let isSole) = slot { isSole } else { false }
  }

  var moveBehavior: MoveBehavior {
    switch slot {
    case .main, .pending: .disabled
    case .pinnedTail: .pinned(repositoryID)
    case .unpinnedTail: .unpinned(repositoryID)
    }
  }

  /// Only the pinned and unpinned tails participate in branch nesting.
  /// The main and pending slots are structural and shouldn't be folded into a tree.
  var supportsBranchNesting: Bool {
    switch slot {
    case .pinnedTail, .unpinnedTail: true
    case .main, .pending: false
    }
  }
}

/// Per-repo tally of rows hoisted into the highlight sections, surfaced as a
/// muted summary line at the bottom of the repo section so a hoisted row stays
/// discoverable from its origin repo without rendering a duplicate. `revealTarget`
/// is the row a click scrolls to: the repo's first pinned hoist, else its first
/// active hoist.
struct SidebarHoistSummary: Equatable, Sendable {
  let pinnedCount: Int
  let activeCount: Int
  let revealTarget: Worktree.ID

  /// Nil when neither bucket has a row, so a `(0, 0)` summary is unrepresentable.
  init?(pinnedCount: Int, activeCount: Int, revealTarget: Worktree.ID) {
    guard pinnedCount > 0 || activeCount > 0 else { return nil }
    self.pinnedCount = pinnedCount
    self.activeCount = activeCount
    self.revealTarget = revealTarget
  }

  /// Spoken VoiceOver form, pinned before active, omitting a zero bucket.
  var label: String {
    var parts: [String] = []
    if pinnedCount > 0 { parts.append("+\(pinnedCount) \(SidebarStructure.HighlightKind.pinned.summaryNoun)") }
    if activeCount > 0 { parts.append("+\(activeCount) \(SidebarStructure.HighlightKind.active.summaryNoun)") }
    return parts.joined(separator: ", ")
  }
}

/// Single source of truth for what the sidebar List renders. The reducer
/// builds it once per `recomputeSidebarStructure()` and caches it on
/// `RepositoriesFeature.State.sidebarStructure`; the view walks `sections`
/// and does no layout calculation itself.
struct SidebarStructure: Equatable, Sendable {
  enum HighlightKind: String, Equatable, Sendable {
    case pinned
    case active

    var title: String {
      switch self {
      case .pinned: "Pinned"
      case .active: "Active"
      }
    }

    /// Lowercase noun used in the per-repo hoist summary line.
    var summaryNoun: String {
      switch self {
      case .pinned: "pinned"
      case .active: "active"
      }
    }
  }

  enum Section: Equatable, Sendable, Identifiable {
    case highlight(kind: HighlightKind, rowIDs: [Worktree.ID])
    case repository(repositoryID: Repository.ID, groups: [SidebarItemGroup])
    case folder(repositoryID: Repository.ID, rowID: Worktree.ID)
    case failedRepository(
      repositoryID: Repository.ID,
      rootURL: URL,
      customTitle: String?,
      color: RepositoryColor?,
      isRemote: Bool
    )
    /// A persisted local git root whose worktrees can't be listed right now
    /// because git itself is environment-blocked. Not broken, so it's a warning
    /// row (not a removable failure row); the bottom banner carries the remedy.
    case environmentBlockedRepository(
      repositoryID: Repository.ID,
      rootURL: URL,
      customTitle: String?,
      color: RepositoryColor?
    )
    case placeholder

    var id: SectionID {
      switch self {
      case .highlight(let kind, _): .highlight(kind)
      case .repository(let repositoryID, _): .repository(repositoryID)
      case .folder(let repositoryID, _): .folder(repositoryID)
      case .failedRepository(let repositoryID, _, _, _, _): .failedRepository(repositoryID)
      case .environmentBlockedRepository(let repositoryID, _, _, _): .environmentBlockedRepository(repositoryID)
      case .placeholder: .placeholder
      }
    }

    enum SectionID: Hashable, Sendable {
      case highlight(HighlightKind)
      case repository(Repository.ID)
      case folder(Repository.ID)
      case failedRepository(Repository.ID)
      case environmentBlockedRepository(Repository.ID)
      case placeholder
    }
  }

  var sections: [Section]
  /// Union of every hoisted row across the highlight sections. Per-repo
  /// payloads have already filtered against this set; exposed for hotkey
  /// consumers and ad-hoc lookups.
  var hoistedRowIDs: Set<Worktree.ID>
  /// Pre-projected menu slots for `focusedSceneValue(\.visibleHotkeyWorktreeRows, …)`.
  var hotkeySlots: [HotkeyWorktreeSlot]
  /// Visible top-down position of each hotkey-eligible row, used by the
  /// view's `commandKeyObserver`-gated shortcut hint render.
  var slotByID: [Worktree.ID: Int]
  /// Per-repo color + name payload used to render the `repo · trail`
  /// subtitle on highlight rows. Built only for repos that contributed at
  /// least one row to the highlight sections.
  var repositoryHighlightByID: [Repository.ID: SidebarHighlightRepoTag]
  /// Per-repo hoisted-row tally; git repos only, built only for repos that
  /// contributed at least one highlight row.
  var hoistSummaryByRepositoryID: [Repository.ID: SidebarHoistSummary]
  /// Outer-ForEach data ordering for repository sections. The view uses
  /// this to translate `.onMove` flat offsets into the index space the
  /// `.repositoriesMoved` reducer action expects.
  var reorderableRepositoryIDs: [Repository.ID]

  static let empty = SidebarStructure(
    sections: [],
    hoistedRowIDs: [],
    hotkeySlots: [],
    slotByID: [:],
    repositoryHighlightByID: [:],
    hoistSummaryByRepositoryID: [:],
    reorderableRepositoryIDs: []
  )

  /// First-frame value used before the reducer recomputes. Surfaces the
  /// placeholder section immediately so the sidebar isn't blank during the
  /// brief window between `init` and the first `.task` effect.
  static let placeholder = SidebarStructure(
    sections: [.placeholder],
    hoistedRowIDs: [],
    hotkeySlots: [],
    slotByID: [:],
    repositoryHighlightByID: [:],
    hoistSummaryByRepositoryID: [:],
    reorderableRepositoryIDs: []
  )
}

extension RepositoriesFeature.State {
  /// Equatable-diffs the freshly-built structure against the cached one so a
  /// no-op rebuild doesn't invalidate SwiftUI observation.
  mutating func recomputeSidebarStructureIfChanged() {
    @Shared(.sidebarGroupPinnedRows) var groupPinned
    @Shared(.sidebarGroupActiveRows) var groupActive
    let new = computeSidebarStructure(
      groupPinned: groupPinned,
      groupActive: groupActive
    )
    if new != sidebarStructure {
      sidebarStructure = new
    }
  }

  /// Refreshes the cached `selectedWorktreeSlice` from the focused row, using
  /// an Equatable diff so observation only invalidates on a real change.
  /// Mirrors `recomputeSidebarStructureIfChanged()` for slice-affecting
  /// actions; per-leaf reads on `sidebarItems[id:]` happen here, not in views.
  mutating func recomputeSelectedWorktreeSliceIfChanged() {
    let new = selectedRow(for: selectedWorktreeID).map { SelectedWorktreeSlice($0) }
    if new != selectedWorktreeSlice {
      selectedWorktreeSlice = new
    }
  }

  /// Refreshes the cached `sidebarSelectionSlice` from the effective selection,
  /// Equatable-diffed so a no-op rebuild doesn't invalidate the sidebar's
  /// observation surface. Kept off `sidebarStructure` so an arrow-key selection
  /// move recomputes a `|selection|`-sized value, not the whole render plan.
  mutating func recomputeSidebarSelectionSliceIfChanged() {
    let new = computeSidebarSelectionSlice()
    if new != sidebarSelectionSlice {
      sidebarSelectionSlice = new
    }
  }

  /// Drops open-action entries for repositories that left the roster. Pure: the
  /// resolution itself reads disk and lives in `.resolveOpenActions`, but pruning
  /// needs nothing but the roster.
  mutating func pruneOpenActionsForRemovedRepositoriesIfChanged() {
    guard openActionByRepositoryID.contains(where: { repositories[id: $0.key] == nil }) else { return }
    openActionByRepositoryID = openActionByRepositoryID.filter { repositories[id: $0.key] != nil }
  }

  /// Equatable-diffs the toolbar notification snapshot against the cache so a
  /// per-row notification append only invalidates SwiftUI when the toolbar
  /// projection actually changes.
  mutating func recomputeToolbarNotificationGroupsIfChanged() {
    let new = computeToolbarNotificationGroups()
    if new != toolbarNotificationGroupsCache {
      toolbarNotificationGroupsCache = new
    }
  }

  /// Equatable-diffs the menu bar sections against the cache so the status menu
  /// only rebuilds when the rows it renders actually change. Computes its own
  /// Pinned/Active hoists (as if sidebar grouping were on), so the menu stays
  /// independent of the user's grouping toggles.
  mutating func recomputeMenuBarSectionsIfChanged() {
    let new = computeMenuBarSections()
    if new != menuBarSectionsCache {
      menuBarSectionsCache = new
    }
  }
}

/// Per-cache invalidation flag set returned by every reducer action. Exhaustive
/// switches over the action enums force every new case to declare which
/// post-reduce caches it touches; a missing case is a compile error rather
/// than a silent "skip the recompute".
struct CacheInvalidations: OptionSet {
  let rawValue: UInt8
  static let sidebarStructure = CacheInvalidations(rawValue: 1 << 0)
  static let selectedWorktreeSlice = CacheInvalidations(rawValue: 1 << 1)
  static let toolbarNotificationGroups = CacheInvalidations(rawValue: 1 << 2)
  static let sidebarSelectionSlice = CacheInvalidations(rawValue: 1 << 3)
  /// Barely a cache recompute: the post-reduce hook prunes entries for dropped
  /// repositories (pure) and launches the off-main resolution effect (the read).
  /// Set it on any arm whose inputs (the repository roster, the installed
  /// editors, the open-action settings) can change the map.
  static let openActionResolution = CacheInvalidations(rawValue: 1 << 4)
  /// The four row-derived sidebar caches. Excludes `.openActionResolution`,
  /// which is keyed by repository: no worktree-level mutation (rename, archive,
  /// delete, customize) can change the open-action map.
  static let allSidebar: CacheInvalidations = [
    .sidebarStructure, .selectedWorktreeSlice, .toolbarNotificationGroups, .sidebarSelectionSlice,
  ]
  /// Every bit: the row-derived caches plus the roster-scoped open-action resolution.
  static let all: CacheInvalidations = [.allSidebar, .openActionResolution]
}

extension SidebarItemFeature.Action {
  var cacheInvalidations: CacheInvalidations {
    switch self {
    // `.sidebarSelectionSlice` because the context menu gates archive / delete
    // / rename on the selected rows' lifecycle.
    case .lifecycleChanged:
      return [.sidebarStructure, .selectedWorktreeSlice, .sidebarSelectionSlice]
    case .agentSnapshotChanged:
      return .sidebarStructure
    // `.selectedWorktreeSlice` because the projection carries the focused row's
    // `runningScripts` (toolbar Run/Stop state). Never `.sidebarSelectionSlice`:
    // this is the per-leaf terminal tick and the selection slice projects none
    // of what it carries, so it must not walk the selection on every notification.
    case .terminalProjectionChanged:
      return [.sidebarStructure, .selectedWorktreeSlice, .toolbarNotificationGroups]
    // `.toolbarNotificationGroups` because the notification header bakes the
    // row's resolved pull-request glyph into that cache.
    case .pullRequestChanged:
      return [.selectedWorktreeSlice, .toolbarNotificationGroups]
    case .diffStatsChanged, .pullRequestQueryStarted,
      .dragSessionChanged,
      .focusTerminalRequested, .focusTerminalConsumed:
      return []
    }
  }
}

extension RepositoriesFeature.Action {
  /// Exhaustive cache-invalidation map. Update this alongside every new
  /// `RepositoriesFeature.Action` case. Adding a case without listing it here
  /// is a compile error (no `default`), so we never silently regress the
  /// "post-reduce skips the recompute" path.
  var cacheInvalidations: CacheInvalidations {
    switch self {
    case .sidebarItems(.element(id: _, action: let inner)):
      return inner.cacheInvalidations
    case .sidebarItems:
      return []

    // Sidebar layout toggles only. `setMoveNotifiedWorktreeToTop` re-sorts the
    // highlight sections (unread float), so a runtime toggle must recompute.
    case .sidebarGroupingTogglesChanged, .sidebarNestByBranchChanged,
      .repositoryExpansionChanged, .branchNestExpansionChanged,
      .setAllSidebarGroupsExpanded,
      .setMoveNotifiedWorktreeToTop,
      .worktreeLineChangesLoaded,
      .consumeTerminalFocus:
      return .sidebarStructure

    // Reorders rewrite the bucket order the selection slice's rows are walked
    // in, so the cached selection order would otherwise go stale.
    case .repositoriesMoved, .pinnedWorktreesMoved, .unpinnedWorktreesMoved:
      return [.sidebarStructure, .sidebarSelectionSlice]

    // Repository-roster changes (repos added, removed, or reloaded): the only
    // bulk arms that rewrite the open-action map's repo keys.
    case .repositoriesLoaded, .openRepositoriesFinished,
      .repositoryRemovalCompleted, .repositoriesRemoved,
      .removeFailedRepository, .remoteRepositoryResolved:
      return .all

    // The other inputs of the open-action map: the installed editors and the
    // per-repo / global open-action settings. Neither touches a sidebar row.
    case .setInstalledOpenActions, .openActionSettingsChanged:
      return .openActionResolution

    // Resolution itself: `.resolveOpenActions` runs the effect the bits above
    // arm, and `.openActionsResolved` only stores its result. Neither may re-arm
    // resolution, or the two would feed each other.
    case .resolveOpenActions, .openActionsResolved:
      return []

    // Worktree-set changes inside an unchanged repo roster.
    case .archiveWorktreeApply, .unarchiveWorktree,
      .deleteWorktreeApply, .worktreeDeleted,
      .createWorktreeInRepository, .createRandomWorktreeInRepository,
      .autoDeleteExpiredArchivedWorktrees:
      return .allSidebar

    // `worktreeInfoEvent` is a pure effect-launcher (HEAD watcher tick): the
    // arm only spawns `.run { ... await send(.branchNameLoaded(...)) }` etc.
    // and never mutates `state`. The downstream `.worktreeBranchNameLoaded` /
    // `.repositoryPullRequestsLoaded` arms declare their own invalidations.
    case .worktreeInfoEvent:
      return []

    // Pure effect launcher: spawns the async SSH resolution, mutates no state.
    // The per-repo `.remoteRepositoryResolved` results recompute the caches.
    case .resolveRemoteRepositories:
      return []

    // Pure signals observed by AppFeature to drain a parked CLI ack; no state.
    case .cliWorktreeAckCancelled, .archiveWorktreeApplied, .archiveWorktreeApplyFailed:
      return []

    // `worktreeBranchNameLoaded` mutates `worktree.name` via `updateWorktreeName`,
    // which feeds `computeToolbarNotificationGroups()` (notification group title).
    // Without `.toolbarNotificationGroups` the popover would show the old name
    // until an unrelated bulk action recomputed the cache.
    case .worktreeBranchNameLoaded:
      return .allSidebar

    // Layout + slices but not the notification snapshot (no notification touch).
    // The pin flips and the create / script paths rewrite `isPinned`, the row
    // roster, or the selection, all of which the selection slice projects.
    case .createRandomWorktreeSucceeded, .createRandomWorktreeFailed,
      .pendingWorktreeProgressUpdated,
      .archiveScriptCompleted, .deleteScriptCompleted, .scriptCompleted,
      .consumeSetupScript,
      .pinWorktree, .unpinWorktree:
      return [.sidebarStructure, .selectedWorktreeSlice, .sidebarSelectionSlice]

    // Pull-request data isn't projected into the selection slice.
    case .repositoryPullRequestsLoaded:
      return [.sidebarStructure, .selectedWorktreeSlice]

    // Selection changes refresh both selection-derived caches.
    case .selectionChanged, .selectWorktree, .selectArchivedWorktrees,
      .selectNextWorktree, .selectPreviousWorktree, .selectWorktreeAtHotkeySlot,
      .worktreeHistoryBack, .worktreeHistoryForward,
      .setSidebarSelectedWorktreeIDs:
      return [.selectedWorktreeSlice, .sidebarSelectionSlice]

    // Repo customization save mutates the section title / color, which flow
    // into the sidebar layout's highlight tag and the notification group name.
    case .repositoryCustomization(.presented(.delegate(.save))):
      return .allSidebar
    case .repositoryCustomization:
      return []

    // Worktree customization save mutates the bucketed Item's title / color, picked up via
    // per-row `customTitle` / `customTint` mirror (highlight tags + notification group name).
    case .worktreeCustomization(.presented(.delegate(.save))):
      return .allSidebar
    // Deeplink / CLI appearance update mutates the same fields as the sheet save.
    case .setWorktreeAppearance:
      return .allSidebar
    case .worktreeCustomization:
      return []

    // Branch rename updates the worktree.name shown in the sidebar row and notification group.
    case .renameBranchPrompt(.presented(.delegate(.renamed))):
      return .allSidebar
    case .renameBranchPrompt:
      return []

    // The two confirm handlers that seed `removingRepositoryIDs` and resync the
    // sidebar. `syncSidebar` is the only path that births or kills a row, and it
    // flips a pending row's lifecycle to `.deleting`, which every row-derived
    // cache projects (the context menu gates archive / delete / rename on it).
    case .alert(.presented(.confirmDeleteSidebarItems)),
      .alert(.presented(.confirmDeleteRepository)):
      return .allSidebar
    // The remaining alert arms only clear `state.alert` and forward an action;
    // the forwarded action declares its own invalidations. Listed one by one so a
    // new alert that mutates a row cannot default into this bucket.
    case .alert(.presented(.confirmArchiveWorktree)),
      .alert(.presented(.confirmArchiveWorktrees)),
      .alert(.presented(.confirmRemoveFailedRepository)),
      .alert(.presented(.viewTerminalTab)),
      .alert(.dismiss):
      return []

    // Everything else is UI / effects / transient state, no cache touched.
    case .task, .setOpenPanelPresented,
      .requestAddRemoteRepository, .requestEditRemoteRepository, .remoteConnectionForm,
      .requestCloneRepository, .cloneRepositoryForm,
      .loadPersistedRepositories,
      .removeRemoteRepository,
      .refreshWorktrees, .reloadRepositories,
      // Blocked-git warning rows recompute via the paired bulk load action that
      // always follows `.gitEnvironmentChanged`, so this needs no invalidation.
      .gitEnvironmentChanged,
      .openRepositories,
      .revealSelectedWorktreeInSidebar, .revealHoistedWorktreeInSidebar,
      .consumePendingSidebarReveal,
      .createRandomWorktree,
      .promptedWorktreeCreationDataLoaded, .promptedWorktreeBranchesLoaded,
      .startPromptedWorktreeCreation,
      .promptedWorktreeCreationChecked,
      .requestArchiveWorktree, .requestArchiveWorktrees,
      .archiveWorktreeConfirmed,
      .requestDeleteSidebarItems, .deleteSidebarItemConfirmed,
      .deleteWorktreeFailed,
      .requestDeleteRepository, .requestRemoveFailedRepository,
      .presentAlert,
      .refreshGithubIntegrationAvailability,
      .githubIntegrationAvailabilityUpdated,
      .repositoryPullRequestRefreshCompleted,
      .setGithubIntegrationEnabled,
      .setMergedWorktreeAction,
      .setAutoDeleteArchivedWorktreesAfterDays,
      .pullRequestAction,
      .showToast, .dismissToast,
      .toggleInspectorPane, .setInspectorPresented,
      .delayedPullRequestRefresh,
      .openRepositorySettings, .requestCustomizeRepository,
      .requestCustomizeWorktree,
      .requestRenameBranch,
      .contextMenuOpenWorktree,
      .worktreeCreationPrompt,
      .delegate:
      return []
    }
  }
}

extension RepositoriesFeature.State {
  /// Single source of truth for the post-reduce cache recompute. The
  /// production hook in `RepositoriesFeature.body` and the test mirror in
  /// `RepositoriesSidebarTestHelpers` both call this so a new cache lands
  /// in one place instead of needing two coordinated updates.
  ///
  /// Pure by contract: every recompute here is a function of state alone.
  /// `.openActionResolution` only prunes here; resolving an entry reads that
  /// repository's `supacode.json`, and a reducer must not touch disk.
  @MainActor
  mutating func applyCacheRecomputes(_ invalidations: CacheInvalidations) {
    if invalidations.contains(.sidebarStructure) {
      recomputeSidebarStructureIfChanged()
    }
    if invalidations.contains(.selectedWorktreeSlice) {
      recomputeSelectedWorktreeSliceIfChanged()
    }
    if invalidations.contains(.sidebarSelectionSlice) {
      recomputeSidebarSelectionSliceIfChanged()
    }
    if invalidations.contains(.toolbarNotificationGroups) {
      recomputeToolbarNotificationGroupsIfChanged()
    }
    // The menu bar rows key off notifications *and* agent activity, and agent
    // snapshots only invalidate `.sidebarStructure`, so they need both flags.
    if !invalidations.isDisjoint(with: [.sidebarStructure, .toolbarNotificationGroups]) {
      recomputeMenuBarSectionsIfChanged()
    }
    if invalidations.contains(.openActionResolution) {
      pruneOpenActionsForRemovedRepositoriesIfChanged()
    }
  }

  /// Pinned worktree IDs across every repository in the user's repo order.
  /// Git main worktrees are excluded (they belong to the per-repo main slot,
  /// not the user-curated pinned list). Folders seed into `.unpinned` by
  /// default and only appear here after an explicit pin. Archived rows are
  /// filtered for parity with the Active candidate filter. The optional
  /// `archived` parameter lets a caller share an already-computed set with
  /// the aggregator so the O(R) walk runs once per call body, not twice.
  func orderedHighlightPinnedIDs(archived: Set<Worktree.ID>? = nil) -> [SidebarItemID] {
    let archivedSet = archived ?? archivedWorktreeIDSet
    var ids: [SidebarItemID] = []
    for repoID in orderedRepositoryIDs() {
      guard let repository = repositories[id: repoID] else { continue }
      let isGit = repository.isGitRepository
      for worktreeID in sidebar.sections[repoID]?.buckets[.pinned]?.items.keys ?? [] {
        if isGit, let worktree = repository.worktrees[id: worktreeID], isMainWorktree(worktree) {
          continue
        }
        if archivedSet.contains(worktreeID) { continue }
        ids.append(worktreeID)
      }
    }
    return ids
  }

  /// Derive the full sidebar render plan in a single pass. Called by the
  /// reducer (see `recomputeSidebarStructure(...)`); never call from a view
  /// body or the per-leaf reads here will observation-track every row at
  /// the parent and reintroduce the regression commit `0a1ed578` documents.
  /// Local git roots we can't read because git is environment-blocked: present
  /// in `repositoryRoots` but with no loaded repository and no failure entry
  /// while the gate is active. Rendered as warning rows, and shielded from
  /// terminal prune so a transient gate doesn't tear down their live sessions.
  var environmentBlockedRepositoryIDs: Set<Repository.ID> {
    guard gitEnvironmentError != nil else { return [] }
    return Set(
      repositoryRoots
        .map { RepositoryID($0.standardizedFileURL.path(percentEncoded: false)) }
        .filter { repositories[id: $0] == nil && loadFailuresByID[$0] == nil }
    )
  }

  func computeSidebarStructure(
    groupPinned: Bool,
    groupActive: Bool
  ) -> SidebarStructure {
    if !isInitialLoadComplete, repositories.isEmpty {
      return SidebarStructure(
        sections: [.placeholder],
        hoistedRowIDs: [],
        hotkeySlots: [],
        slotByID: [:],
        repositoryHighlightByID: [:],
        hoistSummaryByRepositoryID: [:],
        reorderableRepositoryIDs: []
      )
    }

    let hoists = computeHighlightHoists(groupPinned: groupPinned, groupActive: groupActive)
    let repoSections = buildRepositorySections(hoisted: hoists.hoistedSet)

    var sections: [SidebarStructure.Section] = []
    if !hoists.pinned.isEmpty {
      sections.append(.highlight(kind: .pinned, rowIDs: hoists.pinned))
    }
    if !hoists.active.isEmpty {
      sections.append(.highlight(kind: .active, rowIDs: hoists.active))
    }
    sections.append(contentsOf: repoSections.sections)

    let hotkey = computeHotkeyOrdering(
      pinnedHoisted: hoists.pinned,
      activeHoisted: hoists.active,
      hoisted: hoists.hoistedSet,
      sections: sections
    )

    let highlightProjections = computeRepositoryHighlightProjections(
      pinnedHoisted: hoists.pinned,
      activeHoisted: hoists.active
    )

    return SidebarStructure(
      sections: sections,
      hoistedRowIDs: hoists.hoistedSet,
      hotkeySlots: hotkey.slots,
      slotByID: hotkey.slotByID,
      repositoryHighlightByID: highlightProjections.tags,
      hoistSummaryByRepositoryID: highlightProjections.summaries,
      reorderableRepositoryIDs: repoSections.reorderableRepositoryIDs
    )
  }

  /// Pinned and Active hoists computed as if both sidebar grouping toggles were
  /// enabled, so the menu bar always lists them regardless of the user's sidebar
  /// grouping preference. Carries their union for the menu's Unread dedupe.
  func menuBarForcedHoists() -> HighlightHoists {
    computeHighlightHoists(groupPinned: true, groupActive: true)
  }

  /// Hoisted-row payload for one highlight-hoist pass (the sidebar structure
  /// pass, or the menu bar's forced-on pass).
  struct HighlightHoists {
    var pinned: [Worktree.ID]
    var active: [Worktree.ID]
    var hoistedSet: Set<Worktree.ID>
  }

  private func computeHighlightHoists(groupPinned: Bool, groupActive: Bool) -> HighlightHoists {
    let archived = archivedWorktreeIDSet
    let pinned: [Worktree.ID]
    if groupPinned {
      let pinnedIDs = orderedHighlightPinnedIDs(archived: archived)
      pinned = orderedHighlightCandidates(forPinned: true, candidateIDs: pinnedIDs, excluding: [])
    } else {
      pinned = []
    }
    var hoistedSet: Set<Worktree.ID> = Set(pinned)

    let active: [Worktree.ID]
    if groupActive {
      let candidateIDs = sidebarItems.ids.filter { id in
        guard !archived.contains(id) else { return false }
        guard let item = sidebarItems[id: id] else { return false }
        // Terminating rows already signal their wind-down inline.
        guard !item.lifecycle.isTerminating else { return false }
        // Orphan rows have no working dir for the agent/script badge to act on.
        return !item.isMissing
      }
      active = orderedHighlightCandidates(
        forPinned: false,
        candidateIDs: Array(candidateIDs),
        excluding: hoistedSet
      )
      hoistedSet.formUnion(active)
    } else {
      active = []
    }
    return HighlightHoists(pinned: pinned, active: active, hoistedSet: hoistedSet)
  }

  /// Per-repo dispatch output.
  private struct RepositorySectionsBuild {
    var sections: [SidebarStructure.Section]
    var reorderableRepositoryIDs: [Repository.ID]
  }

  private func buildRepositorySections(hoisted: Set<Worktree.ID>) -> RepositorySectionsBuild {
    var sections: [SidebarStructure.Section] = []
    var reorderableRepositoryIDs: [Repository.ID] = []
    let blockedRepositoryIDs = environmentBlockedRepositoryIDs
    let pendingIDsByRepo: [Repository.ID: Set<Worktree.ID>] = Dictionary(
      grouping: pendingWorktrees,
      by: \.repositoryID
    ).mapValues { Set($0.map(\.id)) }
    // Failed local repos have no `repositories[id:]` entry, so resolve their
    // root from the persisted `repositoryRoots` instead.
    let localRootsByID: [Repository.ID: URL] = Dictionary(
      uniqueKeysWithValues: repositoryRoots.map {
        (RepositoryID($0.standardizedFileURL.path(percentEncoded: false)), $0.standardizedFileURL)
      }
    )

    // Local and remote repositories share one flat, reorderable order driven by
    // `orderedRepositoryIDs()` (local roots and host-keyed remote ids honoring
    // the persisted sidebar order). Remote repos are no longer pinned below the
    // local ones: the user can interleave local and remote rows by drag.
    // `reorderableRepositoryIDs` mirrors `orderedRepositoryIDs()` 1:1 (even ids
    // with no rendered section, e.g. a still-loading root or a hoisted folder)
    // so the offset-based `.repositoriesMoved` move maps cleanly back.
    for repositoryID in orderedRepositoryIDs() {
      reorderableRepositoryIDs.append(repositoryID)
      let repository = repositories[id: repositoryID]
      let isRemote = repository?.host != nil

      // A disconnected remote keeps a placeholder repository (so it isn't
      // pruned) plus a load failure; render it like a missing local folder.
      if loadFailuresByID[repositoryID] != nil {
        guard let rootURL = localRootsByID[repositoryID] ?? repository?.rootURL else { continue }
        let sectionEntry = sidebar.sections[repositoryID]
        // A folder's custom name / color live on its synthetic folder-worktree
        // item (the row is a worktree row), not the section, so fall back to it.
        let folderItem = sectionEntry?.folderWorktreeItem(for: repositoryID)
        sections.append(
          .failedRepository(
            repositoryID: repositoryID,
            rootURL: rootURL,
            customTitle: sectionEntry?.title ?? folderItem?.title,
            color: sectionEntry?.color ?? folderItem?.color,
            isRemote: isRemote
          )
        )
        continue
      }

      // A git root we couldn't list because git itself is environment-blocked.
      // Surface a warning row so the repo doesn't look removed. Folder roots keep
      // a repository entry, so they never fall here.
      if blockedRepositoryIDs.contains(repositoryID), let rootURL = localRootsByID[repositoryID] {
        let sectionEntry = sidebar.sections[repositoryID]
        let folderItem = sectionEntry?.folderWorktreeItem(for: repositoryID)
        sections.append(
          .environmentBlockedRepository(
            repositoryID: repositoryID,
            rootURL: rootURL,
            customTitle: sectionEntry?.title ?? folderItem?.title,
            color: sectionEntry?.color ?? folderItem?.color
          )
        )
        continue
      }

      guard let repository else { continue }

      if !repository.isGitRepository {
        // Local folder rows key off the path-derived synthetic id; a remote
        // folder uses its synthetic worktree's own host-keyed id so it never
        // collides with a local folder at the same path.
        let folderRowID =
          isRemote ? repository.worktrees.first?.id : Repository.folderWorktreeID(for: repository.rootURL)
        guard let folderRowID, !hoisted.contains(folderRowID) else { continue }
        sections.append(.folder(repositoryID: repositoryID, rowID: folderRowID))
        continue
      }

      let groups = SidebarItemGroup.computeSlots(
        in: self,
        repositoryID: repositoryID,
        pendingIDs: pendingIDsByRepo[repositoryID] ?? [],
        hoistedRowIDs: hoisted,
        nestWorktreesByBranch: sidebarNestWorktreesByBranch && repository.isGitRepository
      )
      sections.append(.repository(repositoryID: repositoryID, groups: groups))
    }

    return RepositorySectionsBuild(
      sections: sections,
      reorderableRepositoryIDs: reorderableRepositoryIDs
    )
  }

  /// Hotkey assignment output for a single structure pass.
  private struct HotkeyOrdering {
    var slots: [HotkeyWorktreeSlot]
    var slotByID: [Worktree.ID: Int]
  }

  private func computeHotkeyOrdering(
    pinnedHoisted: [Worktree.ID],
    activeHoisted: [Worktree.ID],
    hoisted: Set<Worktree.ID>,
    sections: [SidebarStructure.Section]
  ) -> HotkeyOrdering {
    let perRepoVisibleIDs = hotkeyEligibleIDs(in: sections)
    var order: [Worktree.ID] = []
    order.reserveCapacity(pinnedHoisted.count + activeHoisted.count + perRepoVisibleIDs.count)
    order.append(contentsOf: pinnedHoisted)
    order.append(contentsOf: activeHoisted)
    for id in perRepoVisibleIDs where !hoisted.contains(id) {
      order.append(id)
    }
    var slotByID: [Worktree.ID: Int] = [:]
    slotByID.reserveCapacity(order.count)
    for (index, id) in order.enumerated() {
      slotByID[id] = index
    }
    return HotkeyOrdering(slots: hotkeyWorktreeSlots(for: order), slotByID: slotByID)
  }

  /// Per-repo highlight projections derived in a single walk of the hoisted
  /// arrays.
  private struct HighlightProjections {
    var tags: [Repository.ID: SidebarHighlightRepoTag]
    var summaries: [Repository.ID: SidebarHoistSummary]
  }

  /// Resolve the highlight tags (every contributing repo) and the hoist
  /// summaries (git repos only) in one pass. Walks the ordered arrays, not
  /// `hoistedSet`, so `revealTarget` is deterministic: a repo's first pinned
  /// hoist, else its first active.
  private func computeRepositoryHighlightProjections(
    pinnedHoisted: [Worktree.ID],
    activeHoisted: [Worktree.ID]
  ) -> HighlightProjections {
    guard !pinnedHoisted.isEmpty || !activeHoisted.isEmpty else {
      return HighlightProjections(tags: [:], summaries: [:])
    }

    var contributingRepoIDs: Set<Repository.ID> = []
    var pinnedCounts: [Repository.ID: Int] = [:]
    var activeCounts: [Repository.ID: Int] = [:]
    var firstPinned: [Repository.ID: Worktree.ID] = [:]
    var firstActive: [Repository.ID: Worktree.ID] = [:]

    for id in pinnedHoisted {
      guard let repoID = sidebarItems[id: id]?.repositoryID else { continue }
      contributingRepoIDs.insert(repoID)
      pinnedCounts[repoID, default: 0] += 1
      if firstPinned[repoID] == nil { firstPinned[repoID] = id }
    }
    for id in activeHoisted {
      guard let repoID = sidebarItems[id: id]?.repositoryID else { continue }
      contributingRepoIDs.insert(repoID)
      activeCounts[repoID, default: 0] += 1
      if firstActive[repoID] == nil { firstActive[repoID] = id }
    }

    // Output is keyed by repo id, so build order is irrelevant.
    var tags: [Repository.ID: SidebarHighlightRepoTag] = [:]
    var summaries: [Repository.ID: SidebarHoistSummary] = [:]
    for repoID in contributingRepoIDs {
      guard let repository = repositories[id: repoID] else { continue }
      let section = sidebar.sections[repoID]
      tags[repoID] = SidebarHighlightRepoTag(
        repoName: Repository.sidebarDisplayName(custom: section?.title, fallback: repository.name),
        repoColor: section?.color,
        hostInfo: repository.host?.displayAuthority
      )
      guard repository.isGitRepository, let revealTarget = firstPinned[repoID] ?? firstActive[repoID] else {
        continue
      }
      summaries[repoID] = SidebarHoistSummary(
        pinnedCount: pinnedCounts[repoID] ?? 0,
        activeCount: activeCounts[repoID] ?? 0,
        revealTarget: revealTarget
      )  // Non-nil: `revealTarget` exists only when a bucket contributed a row.
    }
    return HighlightProjections(tags: tags, summaries: summaries)
  }

  /// Walk the freshly-built sections to extract visible per-repo row IDs in
  /// the same top-down order the user sees them. Skips group headers (only
  /// leaves get hotkeys) and falls back to `orderedSidebarItemIDs` for repo
  /// sections where branch nesting hides some rows inside collapsed groups.
  private func hotkeyEligibleIDs(in sections: [SidebarStructure.Section]) -> [Worktree.ID] {
    let expandedRepoIDs = expandedRepositoryIDs
    let nestingFilter = orderedSidebarItemIDs(includingRepositoryIDs: expandedRepoIDs)
    let visibleSet = Set(nestingFilter)
    var ids: [Worktree.ID] = []
    for section in sections {
      switch section {
      case .highlight, .placeholder, .failedRepository, .environmentBlockedRepository:
        continue
      case .folder(_, let rowID):
        ids.append(rowID)
      case .repository(let repositoryID, let groups):
        guard expandedRepoIDs.contains(repositoryID) else { continue }
        for group in groups {
          for rowID in group.rowIDs where visibleSet.contains(rowID) {
            ids.append(rowID)
          }
        }
      }
    }
    return ids
  }

  /// Materialize candidates by reading branchName + notification / classification
  /// flags from each leaf, then delegate to the pure `SidebarHighlightOrdering`
  /// sorter. `moveNotifiedWorktreeToTop` floats unread rows to the top.
  private func orderedHighlightCandidates(
    forPinned: Bool,
    candidateIDs: [SidebarItemID],
    excluding: Set<Worktree.ID>
  ) -> [Worktree.ID] {
    var candidates: [SidebarHighlightOrdering.Candidate] = []
    candidates.reserveCapacity(candidateIDs.count)
    for id in candidateIDs {
      if excluding.contains(id) { continue }
      guard let state = sidebarItems[id: id] else { continue }
      candidates.append(
        SidebarHighlightOrdering.Candidate(
          id: id,
          branchName: state.branchName,
          isNotified: state.hasUnseenNotifications,
          classification: SidebarActiveClassification.classify(state)
        )
      )
    }
    return SidebarHighlightOrdering.orderedRowIDs(
      forPinned: forPinned,
      prioritizeNotified: moveNotifiedWorktreeToTop,
      candidates: candidates
    )
  }
}

extension SidebarItemGroup {
  /// Split one repo's bucketed item IDs into the four ordered slots the
  /// sidebar renders (`main`, `pinnedTail`, `pending`, `unpinnedTail`), then
  /// filter against `hoistedRowIDs` and dedupe across slots via a seen-set
  /// so a row that survived a pre-existing double-bucket pre-state renders
  /// in at most one position (priority order: main > pinnedTail > pending >
  /// unpinnedTail).
  ///
  /// `nestWorktreesByBranch` should be the effective per-repo value
  /// (`@Shared(.sidebarNestWorktreesByBranch)` gated on `isGitRepository`).
  /// When set, the pinned and unpinned tails are sorted by branch name
  /// (case-insensitive) to match `SidebarBranchNesting.buildRows`, so the
  /// hotkey / arrow projection that walks `rowIDs` sees the same top-down
  /// order the view renders. Main and pending slots stay in bucket order
  /// (they don't participate in branch nesting).
  static func computeSlots(
    in state: RepositoriesFeature.State,
    repositoryID: Repository.ID,
    pendingIDs: Set<Worktree.ID>,
    hoistedRowIDs: Set<Worktree.ID>,
    nestWorktreesByBranch: Bool
  ) -> [SidebarItemGroup] {
    guard let bucket = state.sidebarGrouping.bucketsByRepository[repositoryID] else { return [] }
    let pinnedRows = bucket[.pinned]
    let unpinnedRows = bucket[.unpinned]

    // Scan the whole pinned bucket: rebuild seeds main at index 0, but a
    // corrupted persisted `.pinned` (hand-edit, migrator race) may surface
    // main at a non-zero position. Matching `orderedPinnedWorktreeIDs`'s
    // any-position filter keeps `pinnedTail` and the reducer's source list
    // in agreement for `translateFilteredMove`.
    let rawMainID: SidebarItemID? = pinnedRows.first(where: { id in
      state.sidebarItems[id: id]?.isMainWorktree == true
    })

    var seen: Set<Worktree.ID> = []
    var mainID: SidebarItemID?
    if let rawMainID {
      seen.insert(rawMainID)
      if !hoistedRowIDs.contains(rawMainID) { mainID = rawMainID }
    }

    var rawPinnedTail: [SidebarItemID] = []
    for id in pinnedRows where id != rawMainID && !seen.contains(id) {
      rawPinnedTail.append(id)
      seen.insert(id)
    }
    var rawPendingTail: [SidebarItemID] = []
    for id in unpinnedRows where pendingIDs.contains(id) && !seen.contains(id) {
      rawPendingTail.append(id)
      seen.insert(id)
    }
    var rawUnpinnedTail: [SidebarItemID] = []
    for id in unpinnedRows where !pendingIDs.contains(id) && !seen.contains(id) {
      rawUnpinnedTail.append(id)
      seen.insert(id)
    }

    // Read live lifecycle here (the `.deletingScript` flip recomputes the
    // structure but not the grouping). Render-only: the surfaced row is absent
    // from the nav, hotkey, and multi-select projections, which exclude archived.
    if let archivedItems = state.sidebar.sections[repositoryID]?.buckets[.archived]?.items {
      for id in archivedItems.keys
      where state.sidebarItems[id: id]?.lifecycle == .deletingScript && !seen.contains(id) {
        rawUnpinnedTail.append(id)
        seen.insert(id)
      }
    }

    var pinnedTail = rawPinnedTail.filter { !hoistedRowIDs.contains($0) }
    let pendingTail = rawPendingTail.filter { !hoistedRowIDs.contains($0) }
    var unpinnedTail = rawUnpinnedTail.filter { !hoistedRowIDs.contains($0) }

    if nestWorktreesByBranch {
      pinnedTail = sortedByBranchName(pinnedTail, in: state)
      unpinnedTail = sortedByBranchName(unpinnedTail, in: state)
    }

    let isSoleDefaultWorktree =
      mainID != nil && pinnedTail.isEmpty && pendingTail.isEmpty && unpinnedTail.isEmpty

    return [
      SidebarItemGroup(
        slot: .main(isSole: isSoleDefaultWorktree),
        repositoryID: repositoryID,
        rowIDs: mainID.map { [$0] } ?? []
      ),
      SidebarItemGroup(
        slot: .pinnedTail,
        repositoryID: repositoryID,
        rowIDs: pinnedTail
      ),
      SidebarItemGroup(
        slot: .pending,
        repositoryID: repositoryID,
        rowIDs: pendingTail
      ),
      SidebarItemGroup(
        slot: .unpinnedTail,
        repositoryID: repositoryID,
        rowIDs: unpinnedTail
      ),
    ]
  }

  /// Case-insensitive sort by `branchName`, matching `SidebarBranchNesting.buildRows`.
  /// Fallback to the row id keeps a transient missing leaf from breaking sort
  /// stability rather than crashing. `id` is the final tie-break so equal
  /// branch names keep a deterministic order.
  private static func sortedByBranchName(
    _ ids: [SidebarItemID],
    in state: RepositoriesFeature.State
  ) -> [SidebarItemID] {
    ids.sorted { lhs, rhs in
      let lhsName = state.sidebarItems[id: lhs]?.branchName ?? lhs.rawValue
      let rhsName = state.sidebarItems[id: rhs]?.branchName ?? rhs.rawValue
      return SidebarHighlightOrdering.branchNameOrdersBefore(lhsName, id: lhs, rhsName, id: rhs)
    }
  }

  /// SwiftUI emits `.onMove` offsets/destination against the *visible* rows
  /// (the post-hoisting filter). The reducer's `pinnedWorktreesMoved` /
  /// `unpinnedWorktreesMoved` mutates the *full* bucket. Translate visible
  /// indices to full-bucket indices before dispatching so a reorder inside a
  /// bucket with hoisted rows lands the dragged row at the visible target
  /// without disturbing hoisted siblings' relative positions.
  ///
  /// Returns `nil` if the inputs disagree (visible id not present in full,
  /// or out-of-range offset / destination); the caller should drop the move.
  static func translateFilteredMove(
    offsets: IndexSet,
    destination: Int,
    visibleIDs: [Worktree.ID],
    fullIDs: [Worktree.ID]
  ) -> (offsets: IndexSet, destination: Int)? {
    guard destination >= 0, destination <= visibleIDs.count else { return nil }
    var fullIndexByID: [Worktree.ID: Int] = [:]
    fullIndexByID.reserveCapacity(fullIDs.count)
    for (index, id) in fullIDs.enumerated() { fullIndexByID[id] = index }

    var translatedOffsets = IndexSet()
    for visibleIndex in offsets {
      guard visibleIDs.indices.contains(visibleIndex) else { return nil }
      guard let fullIndex = fullIndexByID[visibleIDs[visibleIndex]] else { return nil }
      translatedOffsets.insert(fullIndex)
    }

    let translatedDestination: Int
    if destination == visibleIDs.count {
      translatedDestination = fullIDs.count
    } else if let fullIndex = fullIndexByID[visibleIDs[destination]] {
      translatedDestination = fullIndex
    } else {
      return nil
    }
    return (translatedOffsets, translatedDestination)
  }
}

extension SidebarState.Section {
  /// A folder repo's custom title / color live on its synthetic folder-worktree
  /// item (the row is a worktree row), keyed by the repo id string.
  fileprivate func folderWorktreeItem(for repositoryID: Repository.ID) -> SidebarState.Item? {
    let folderID = WorktreeID(repositoryID.rawValue)
    return buckets[.pinned]?.items[folderID] ?? buckets[.unpinned]?.items[folderID]
  }
}
