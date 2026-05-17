import ComposableArchitecture
import OrderedCollections
import SupacodeSettingsShared
import SwiftUI

/// Classification buckets for the Pinned and Active sidebar sections. Lower
/// raw value = higher priority. Rows that don't classify into one of the ten
/// buckets are excluded from the Active section entirely and rendered at the
/// bottom of the Pinned section alphabetically.
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

  /// Read four leaf-local flags from a `SidebarItemFeature.State` and
  /// classify. The state must come from a per-leaf scoped store so observation
  /// is bounded to the leaf. `hasAgent` is keyed off agent badge presence
  /// (any tracked instance, including `.idle`) so a row with a visible agent
  /// badge surfaces in Active even when the agent isn't actively working;
  /// `state.agents` is already empty when badges are disabled by the user.
  static func classify(_ state: SidebarItemFeature.State) -> Self? {
    classify(
      hasUnread: state.hasUnseenNotifications,
      hasAwaiting: state.hasAgentAwaitingInput,
      hasAgent: !state.agents.isEmpty,
      hasRunning: !state.runningScripts.isEmpty
    )
  }
}

extension RepositoriesFeature.State {
  /// Pinned worktree IDs across every repository in the user's repo order.
  /// Git main worktrees are excluded (they belong to the per-repo main slot,
  /// not the user-curated pinned list). Folders seed into `.unpinned` by
  /// default and only appear here after an explicit pin. Archived rows are
  /// filtered for parity with the Active candidate filter. The optional
  /// `archived` parameter lets a caller share an already-computed set with
  /// the aggregator so the O(R) walk runs once per aggregator body, not twice.
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
}

/// Top-of-sidebar aggregator. Per-leaf scoping bounds observation here
/// (AGENTS.md "Sidebar performance") so per-row ticks never bubble up to
/// `SidebarListView` or unrelated rows.
struct SidebarHighlightTopView: View {
  let store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let selectedWorktreeIDs: Set<Worktree.ID>
  let pinnedIDs: [SidebarItemID]
  let repositoryHighlightByID: [Repository.ID: SidebarHighlightRepoTag]
  @Shared(.sidebarHighlightPinnedExpanded) private var pinnedExpanded: Bool
  @Shared(.sidebarHighlightActiveExpanded) private var activeExpanded: Bool

  var body: some View {
    // Reading `sidebarItems.ids` inside this body keeps the observation
    // bounded to the aggregator. The archived set is pre-derived once so the
    // candidate filter is O(R + N) instead of O(N × R).
    let archived = store.state.archivedWorktreeIDSet
    let candidateIDs = store.state.sidebarItems.ids.filter { !archived.contains($0) }
    let pinnedSet = Set(pinnedIDs)
    let pinnedOrdered = orderedRowIDs(forPinned: true, candidates: pinnedIDs, excluding: [])
    let activeOrdered = orderedRowIDs(forPinned: false, candidates: Array(candidateIDs), excluding: pinnedSet)
    let renderPinned = !pinnedOrdered.isEmpty
    let renderActive = !activeOrdered.isEmpty

    if renderPinned {
      Section(isExpanded: Binding($pinnedExpanded)) {
        ForEach(pinnedOrdered, id: \.self) { rowID in
          SidebarHighlightRow(
            rowID: rowID,
            store: store,
            terminalManager: terminalManager,
            selectedWorktreeIDs: selectedWorktreeIDs,
            repositoryHighlightByID: repositoryHighlightByID
          )
        }
      } header: {
        HStack {
          Text("Pinned")
          Image(systemName: "pin.fill")
            .imageScale(.small)
            .accessibilityHidden(true)
        }
      }
    }
    if renderActive {
      Section(isExpanded: Binding($activeExpanded)) {
        ForEach(activeOrdered, id: \.self) { rowID in
          SidebarHighlightRow(
            rowID: rowID,
            store: store,
            terminalManager: terminalManager,
            selectedWorktreeIDs: selectedWorktreeIDs,
            repositoryHighlightByID: repositoryHighlightByID
          )
        }
      } header: {
        HStack {
          Text("Active")
          Image(systemName: "play.fill")
            .imageScale(.small)
            .accessibilityHidden(true)
        }
      }
    }
  }

  /// Per-leaf scope each candidate, then delegate the actual sort to the
  /// pure `SidebarHighlightOrdering` helper so the priority + alphabetical
  /// + exclude-dedup logic stays unit-testable in isolation.
  private func orderedRowIDs(
    forPinned: Bool,
    candidates: [SidebarItemID],
    excluding: Set<SidebarItemID>
  ) -> [SidebarItemID] {
    var snapshots: [SidebarHighlightOrdering.Candidate] = []
    snapshots.reserveCapacity(candidates.count)
    for id in candidates {
      if excluding.contains(id) { continue }
      guard
        let leafStore = store.scope(
          state: \.sidebarItems[id: id], action: \.sidebarItems[id: id]
        )
      else { continue }
      let state = leafStore.state
      snapshots.append(
        SidebarHighlightOrdering.Candidate(
          id: id,
          branchName: state.branchName,
          classification: SidebarActiveClassification.classify(state)
        )
      )
    }
    return SidebarHighlightOrdering.orderedRowIDs(forPinned: forPinned, candidates: snapshots)
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

/// Single highlight-section row. Resolves its repo identity via per-leaf
/// scope so observation stays bounded to the leaf, then forwards into
/// `SidebarItemRow` for the actual draw. Extracted as a struct so each row
/// gets its own SwiftUI identity (per "view subviews as structs").
private struct SidebarHighlightRow: View {
  let rowID: SidebarItemID
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let selectedWorktreeIDs: Set<Worktree.ID>
  let repositoryHighlightByID: [Repository.ID: SidebarHighlightRepoTag]

  var body: some View {
    let highlight =
      store.scope(state: \.sidebarItems[id: rowID], action: \.sidebarItems[id: rowID])
      .flatMap { repositoryHighlightByID[$0.state.repositoryID] }
    SidebarItemRow(
      rowID: rowID,
      store: store,
      terminalManager: terminalManager,
      selectedWorktreeIDs: selectedWorktreeIDs,
      isRepositoryRemoving: false,
      hideSubtitle: false,
      moveMode: .alwaysDisabled,
      shortcutHint: nil,
      highlightSubtitle: highlight
    )
  }
}

extension EnvironmentValues {
  /// Set by `SidebarListView` to the live value of the View-menu toggle.
  /// `SidebarItemContainer` reads it under its per-leaf scope to decide
  /// whether a row is hoisted to Pinned / Active and should suppress itself
  /// from its per-repo section.
  @Entry var sidebarHighlightRelevant: Bool = false
}
