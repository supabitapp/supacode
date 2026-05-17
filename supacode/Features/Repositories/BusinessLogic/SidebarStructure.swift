import ComposableArchitecture
import Dependencies
import Foundation
import OrderedCollections

/// Dependency switch that gates the reducer's post-reduce sidebar-structure
/// recompute. Live + preview default to `true` so production / previews
/// always see the cached structure; tests default to `false` so the
/// hundreds of TestStore expectations that don't care about sidebar layout
/// aren't forced to acknowledge a derived cache mutation. Tests that DO
/// verify the structure flip it back on via `withDependencies { $0.sidebarStructureAutoRecompute = true }`.
public nonisolated enum SidebarStructureAutoRecomputeKey: DependencyKey {
  public static let liveValue: Bool = true
  public static let previewValue: Bool = true
  public static let testValue: Bool = false
}

extension DependencyValues {
  public nonisolated var sidebarStructureAutoRecompute: Bool {
    get { self[SidebarStructureAutoRecomputeKey.self] }
    set { self[SidebarStructureAutoRecomputeKey.self] = newValue }
  }
}

/// Classification buckets for the global Active section. Lower raw value =
/// higher priority. Rows that don't classify into one of the ten buckets are
/// excluded from Active and (when the Pinned section is in play) fall to the
/// bottom of Pinned alphabetically.
enum SidebarActiveClassification: Int, CaseIterable, Comparable, Sendable {
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
    classify(
      hasUnread: state.hasUnseenNotifications,
      hasAwaiting: state.hasAgentAwaitingInput,
      hasAgent: !state.agents.isEmpty,
      hasRunning: !state.runningScripts.isEmpty
    )
  }
}

/// Pure ordering layer behind the highlight aggregator: priority sort over
/// `SidebarActiveClassification`, alphabetical tie-break. Pinned keeps
/// unclassified rows at the bottom; Active drops them.
enum SidebarHighlightOrdering {
  struct Candidate: Equatable, Sendable {
    let id: SidebarItemID
    let branchName: String
    let classification: SidebarActiveClassification?
  }

  static func orderedRowIDs(
    forPinned: Bool,
    candidates: [Candidate]
  ) -> [SidebarItemID] {
    struct Entry {
      let id: SidebarItemID
      let priority: Int
      let sortKey: String
    }
    let unclassifiedPriority = SidebarActiveClassification.allCases.count + 1
    var entries: [Entry] = []
    entries.reserveCapacity(candidates.count)
    for candidate in candidates {
      if forPinned {
        let priority = candidate.classification?.rawValue ?? unclassifiedPriority
        entries.append(Entry(id: candidate.id, priority: priority, sortKey: candidate.branchName))
      } else {
        guard let classification = candidate.classification else { continue }
        entries.append(
          Entry(id: candidate.id, priority: classification.rawValue, sortKey: candidate.branchName)
        )
      }
    }
    entries.sort { lhs, rhs in
      if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
      return lhs.sortKey.localizedCaseInsensitiveCompare(rhs.sortKey) == .orderedAscending
    }
    return entries.map(\.id)
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
  }

  enum Section: Equatable, Sendable, Identifiable {
    case highlight(kind: HighlightKind, rowIDs: [Worktree.ID])
    case repository(repositoryID: Repository.ID, groups: [SidebarItemGroup])
    case folder(repositoryID: Repository.ID, rowID: Worktree.ID)
    case failedRepository(repositoryID: Repository.ID, rootURL: URL, failureMessage: String)
    case placeholder

    var id: ID {
      switch self {
      case .highlight(let kind, _): .highlight(kind)
      case .repository(let repositoryID, _): .repository(repositoryID)
      case .folder(let repositoryID, _): .folder(repositoryID)
      case .failedRepository(let repositoryID, _, _): .failedRepository(repositoryID)
      case .placeholder: .placeholder
      }
    }

    enum ID: Hashable, Sendable {
      case highlight(HighlightKind)
      case repository(Repository.ID)
      case folder(Repository.ID)
      case failedRepository(Repository.ID)
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
    reorderableRepositoryIDs: []
  )
}

extension RepositoriesFeature.State {
  /// Single entry-point the reducer calls after any action that may have
  /// changed structure inputs. Equatable-diffs against the cached value so a
  /// no-op rebuild doesn't invalidate SwiftUI observation.
  ///
  /// Reads the two grouping toggles via local `@Shared` accessors rather
  /// than storing them on State — storing pre-loads UserDefaults at every
  /// `State()` construction in the test suite, which destabilized timing
  /// tests in `WorktreeTerminalManagerTests` (the suite never goes through
  /// the reducer but still incurred the global @Shared init).
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
}

extension RepositoriesFeature.Action {
  /// Coarse predicate naming the actions whose handlers touch
  /// `sidebarItems` / `sidebar` buckets / `repositories` / `expandedRepositoryIDs`
  /// or any other input `SidebarStructure` reads from. Actions absent here
  /// skip the post-reduce recompute entirely (user requirement: don't
  /// rebuild on actions that can't affect the visible sidebar).
  var affectsSidebarStructure: Bool {
    switch self {
    // Every per-leaf mutation flows through the IdentifiedActionOf child.
    case .sidebarItems:
      return true
    // Toggles changed — read by the recompute helper.
    case .sidebarGroupingTogglesChanged:
      return true
    // Repository roster / failure map changed.
    case .repositoriesLoaded, .openRepositoriesFinished,
      .repositoryRemovalCompleted, .repositoriesRemoved,
      .removeFailedRepository:
      return true
    // Expansion + reorder.
    case .repositoryExpansionChanged, .branchNestExpansionChanged,
      .repositoriesMoved, .pinnedWorktreesMoved, .unpinnedWorktreesMoved:
      return true
    // Bucket / pin state.
    case .pinWorktree, .unpinWorktree:
      return true
    // Worktree lifecycle that mutates sidebarItems / pendingWorktrees.
    case .archiveWorktreeApply, .unarchiveWorktree,
      .deleteWorktreeApply, .worktreeDeleted,
      .createRandomWorktreeSucceeded, .createRandomWorktreeFailed,
      .pendingWorktreeProgressUpdated,
      .archiveScriptCompleted, .deleteScriptCompleted, .scriptCompleted,
      .consumeSetupScript, .consumeTerminalFocus,
      .autoDeleteExpiredArchivedWorktrees:
      return true
    // Per-leaf info loaded from background work (changes branchName, PR data).
    case .worktreeBranchNameLoaded, .worktreeLineChangesLoaded,
      .worktreeNotificationReceived, .worktreeInfoEvent,
      .repositoryPullRequestsLoaded:
      return true
    default:
      return false
    }
  }
}

extension RepositoriesFeature.State {
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
  func computeSidebarStructure(
    groupPinned: Bool,
    groupActive: Bool
  ) -> SidebarStructure {
    let placeholderMode = !isInitialLoadComplete && repositories.isEmpty
    if placeholderMode {
      return SidebarStructure(
        sections: [.placeholder],
        hoistedRowIDs: [],
        hotkeySlots: [],
        slotByID: [:],
        repositoryHighlightByID: [:],
        reorderableRepositoryIDs: []
      )
    }

    let archived = archivedWorktreeIDSet

    let pinnedHoisted: [Worktree.ID]
    if groupPinned {
      let pinnedIDs = orderedHighlightPinnedIDs(archived: archived)
      pinnedHoisted = orderedHighlightCandidates(
        forPinned: true,
        candidateIDs: pinnedIDs,
        excluding: []
      )
    } else {
      pinnedHoisted = []
    }
    var hoisted: Set<Worktree.ID> = Set(pinnedHoisted)

    let activeHoisted: [Worktree.ID]
    if groupActive {
      let candidateIDs = sidebarItems.ids.filter { id in
        guard !archived.contains(id) else { return false }
        // A row mid-delete shouldn't surface in the Active rail (C10b);
        // its lifecycle UI already signals the wind-down.
        return sidebarItems[id: id]?.lifecycle != .deletingScript
      }
      activeHoisted = orderedHighlightCandidates(
        forPinned: false,
        candidateIDs: Array(candidateIDs),
        excluding: hoisted
      )
      hoisted.formUnion(activeHoisted)
    } else {
      activeHoisted = []
    }

    // Build the ordered sections list. Highlights come first (in fixed
    // priority order: pinned, then active), then each repo in
    // `orderedRepositoryRoots()` order, dispatching by failed / folder / git.
    var sections: [SidebarStructure.Section] = []
    if !pinnedHoisted.isEmpty {
      sections.append(.highlight(kind: .pinned, rowIDs: pinnedHoisted))
    }
    if !activeHoisted.isEmpty {
      sections.append(.highlight(kind: .active, rowIDs: activeHoisted))
    }

    var reorderableRepositoryIDs: [Repository.ID] = []
    let pendingIDsByRepo: [Repository.ID: Set<Worktree.ID>] = Dictionary(
      grouping: pendingWorktrees,
      by: \.repositoryID
    ).mapValues { Set($0.map(\.id)) }

    for rootURL in orderedRepositoryRoots() {
      let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)
      if let failureMessage = loadFailuresByID[repositoryID] {
        sections.append(
          .failedRepository(
            repositoryID: repositoryID,
            rootURL: rootURL,
            failureMessage: failureMessage
          )
        )
        reorderableRepositoryIDs.append(repositoryID)
        continue
      }
      guard let repository = repositories[id: repositoryID] else { continue }
      reorderableRepositoryIDs.append(repositoryID)
      if !repository.isGitRepository {
        let folderRowID = Repository.folderWorktreeID(for: repository.rootURL)
        if !hoisted.contains(folderRowID) {
          sections.append(.folder(repositoryID: repositoryID, rowID: folderRowID))
        }
        continue
      }
      let groups = SidebarItemGroup.computeSlots(
        in: self,
        repositoryID: repositoryID,
        pendingIDs: pendingIDsByRepo[repositoryID] ?? [],
        hoistedRowIDs: hoisted
      )
      sections.append(.repository(repositoryID: repositoryID, groups: groups))
    }

    let perRepoVisibleIDs = hotkeyEligibleIDs(in: sections)
    var hotkeyOrder: [Worktree.ID] = []
    hotkeyOrder.reserveCapacity(pinnedHoisted.count + activeHoisted.count + perRepoVisibleIDs.count)
    hotkeyOrder.append(contentsOf: pinnedHoisted)
    hotkeyOrder.append(contentsOf: activeHoisted)
    for id in perRepoVisibleIDs where !hoisted.contains(id) {
      hotkeyOrder.append(id)
    }

    let hotkeySlots = hotkeyWorktreeSlots(for: hotkeyOrder)
    var slotByID: [Worktree.ID: Int] = [:]
    slotByID.reserveCapacity(hotkeyOrder.count)
    for (index, id) in hotkeyOrder.enumerated() {
      // Forged duplicates would trap `Dictionary(uniqueKeysWithValues:)`; keep
      // the first slot and assert in DEBUG so a real invariant break surfaces.
      if slotByID[id] != nil {
        assertionFailure("Duplicate Worktree.ID in sidebar hotkey order.")
        continue
      }
      slotByID[id] = index
    }

    var repositoryHighlightByID: [Repository.ID: SidebarHighlightRepoTag] = [:]
    if !hoisted.isEmpty {
      var contributingRepoIDs: Set<Repository.ID> = []
      for id in pinnedHoisted {
        if let repoID = sidebarItems[id: id]?.repositoryID {
          contributingRepoIDs.insert(repoID)
        }
      }
      for id in activeHoisted {
        if let repoID = sidebarItems[id: id]?.repositoryID {
          contributingRepoIDs.insert(repoID)
        }
      }
      for repoID in contributingRepoIDs {
        guard let repository = repositories[id: repoID] else { continue }
        repositoryHighlightByID[repoID] = SidebarHighlightRepoTag(
          repoName: repository.name,
          repoColor: sidebar.sections[repoID]?.color
        )
      }
    }

    return SidebarStructure(
      sections: sections,
      hoistedRowIDs: hoisted,
      hotkeySlots: hotkeySlots,
      slotByID: slotByID,
      repositoryHighlightByID: repositoryHighlightByID,
      reorderableRepositoryIDs: reorderableRepositoryIDs
    )
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
      case .highlight, .placeholder, .failedRepository:
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

  /// Materialize candidates by reading branchName + classification flags
  /// from each leaf, then delegate to the pure `SidebarHighlightOrdering`
  /// sorter.
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
          classification: SidebarActiveClassification.classify(state)
        )
      )
    }
    return SidebarHighlightOrdering.orderedRowIDs(forPinned: forPinned, candidates: candidates)
  }
}

extension SidebarItemGroup {
  /// Split one repo's bucketed item IDs into the four ordered slots the
  /// sidebar renders (`main`, `pinnedTail`, `pending`, `unpinnedTail`), then
  /// filter against `hoistedRowIDs` and dedupe across slots via a seen-set
  /// so a row that survived a pre-existing double-bucket pre-state renders
  /// in at most one position (priority order: main > pinnedTail > pending >
  /// unpinnedTail).
  static func computeSlots(
    in state: RepositoriesFeature.State,
    repositoryID: Repository.ID,
    pendingIDs: Set<Worktree.ID>,
    hoistedRowIDs: Set<Worktree.ID>
  ) -> [SidebarItemGroup] {
    guard let bucket = state.sidebarGrouping.bucketsByRepository[repositoryID] else { return [] }
    let pinnedRows = bucket[.pinned]
    let unpinnedRows = bucket[.unpinned]

    let rawMainID: SidebarItemID? = pinnedRows.first.flatMap {
      state.sidebarItems[id: $0]?.isMainWorktree == true ? $0 : nil
    }

    var seen: Set<Worktree.ID> = []
    if let rawMainID, hoistedRowIDs.contains(rawMainID) { seen.insert(rawMainID) }

    let mainID: SidebarItemID? = rawMainID.flatMap { id in
      hoistedRowIDs.contains(id) ? nil : { seen.insert(id); return id }()
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

    let pinnedTail = rawPinnedTail.filter { !hoistedRowIDs.contains($0) }
    let pendingTail = rawPendingTail.filter { !hoistedRowIDs.contains($0) }
    let unpinnedTail = rawUnpinnedTail.filter { !hoistedRowIDs.contains($0) }

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
}
