import ComposableArchitecture
import Foundation
import OrderedCollections
import SupacodeSettingsShared

extension RepositoriesFeature {
  /// Reconciles per-row data after any roster mutation.
  static func syncSidebar(_ state: inout State) {
    reconcileSidebarItems(&state)
    rebuildSidebarGrouping(&state)
  }

  /// Rebuilds `state.sidebarItems` from the canonical roster, carrying forward
  /// per-row data (lifecycle, diff stats, PR, running scripts) for surviving ids.
  /// Only path that births or kills a row.
  static func reconcileSidebarItems(_ state: inout State) {
    let previousByID = state.sidebarItems
    var rebuilt: IdentifiedArrayOf<SidebarItemFeature.State> = []

    for repository in state.repositories {
      let kind: SidebarItemFeature.State.Kind = repository.isGitRepository ? .gitWorktree : .folder
      for worktree in state.orderedWorktreesIncludingArchivedWithRunningDeleteScript(in: repository) {
        let id = worktree.id
        let existing = previousByID[id: id]
        let isPinned = state.isWorktreePinned(worktree)
        let isMain = state.isMainWorktree(worktree)

        var item =
          existing
          ?? SidebarItemFeature.State(
            id: id,
            repositoryID: repository.id,
            kind: kind,
            name: worktree.name,
            branchName: worktree.name,
            subtitle: worktree.detail.isEmpty ? nil : worktree.detail,
            workingDirectory: worktree.workingDirectory,
            repositoryAccent: nil,
            isMainWorktree: isMain,
            isPinned: isPinned,
            hasMergedBadge: false
          )
        item.name = worktree.name
        item.branchName = worktree.name
        item.subtitle = worktree.detail.isEmpty ? nil : worktree.detail
        item.workingDirectory = worktree.workingDirectory
        item.isMainWorktree = isMain
        item.isPinned = isPinned
        // Clear the PR query branch when the worktree was renamed.
        if let existing, existing.branchName != worktree.name {
          item.pullRequestBranchAtQueryTime = nil
        }
        // Archived rows keep running scripts only while the delete script is
        // active; any leftover scripts are stale and would render as misleading
        // running-state dots in the archived bucket.
        if state.isWorktreeArchived(id), item.lifecycle != .deletingScript,
          !item.runningScripts.isEmpty
        {
          item.runningScripts.removeAll()
        }
        rebuilt.append(item)
      }
      for pending in state.pendingWorktrees where pending.repositoryID == repository.id {
        let id = pending.id
        let existing = previousByID[id: id]
        let pendingName = pending.progress.worktreeName ?? "Creating…"
        var item =
          existing
          ?? SidebarItemFeature.State(
            id: id,
            repositoryID: repository.id,
            kind: .gitWorktree,
            name: pendingName,
            branchName: pendingName,
            subtitle: nil,
            workingDirectory: repository.rootURL,
            repositoryAccent: nil,
            isMainWorktree: false,
            isPinned: false,
            hasMergedBadge: false
          )
        item.name = pendingName
        item.branchName = pendingName
        item.lifecycle =
          state.removingRepositoryIDs[pending.repositoryID] != nil
          ? .deleting
          : .pending
        rebuilt.append(item)
      }
    }
    // Carry forward in-flight rows whose worktree dropped out of the roster
    // mid-archive / mid-delete so the per-target completion handlers can drain
    // them. Rows whose repository is gone from both the roster and the
    // removing-batch set are dropped immediately to prevent orphan leaks
    // (e.g. when `removeFailedRepository` evicts a repo mid-flight).
    let rebuiltIDs = Set(rebuilt.ids)
    for existing in previousByID
    where !rebuiltIDs.contains(existing.id)
      && existing.lifecycle != .idle
      && (state.repositories[id: existing.repositoryID] != nil
        || state.removingRepositoryIDs[existing.repositoryID] != nil)
    {
      rebuilt.append(existing)
    }
    state.sidebarItems = rebuilt
  }

  /// Pair with `reconcileSidebarItems`; recomputes `state.sidebarGrouping`.
  static func rebuildSidebarGrouping(_ state: inout State) {
    var buckets: OrderedDictionary<Repository.ID, SidebarGrouping.BucketGrouping> = [:]

    for repositoryID in state.orderedRepositoryIDs() {
      guard let repository = state.repositories[id: repositoryID] else { continue }
      var bucket = SidebarGrouping.BucketGrouping()
      var pinned: [SidebarItemID] = []
      if let mainWorktree = repository.worktrees.first(where: { state.isMainWorktree($0) }),
        !state.isWorktreeArchived(mainWorktree.id)
      {
        pinned.append(mainWorktree.id)
      }
      pinned.append(contentsOf: state.orderedPinnedWorktreeIDs(in: repository))
      bucket[.pinned] = pinned

      // Mirror the visual order from `sidebarItemGroups`: pending rows render before
      // the non-pending unpinned tail, so the bucket (which drives hotkey ordering)
      // must too. Otherwise Cmd+N's hint and target diverge while a worktree is creating.
      var unpinned: [SidebarItemID] = []
      for pending in state.pendingWorktrees where pending.repositoryID == repositoryID {
        unpinned.append(pending.id)
      }
      unpinned.append(contentsOf: state.orderedUnpinnedWorktreeIDs(in: repository))
      bucket[.unpinned] = unpinned
      // Archived bucket: only worktrees whose delete script is running stay visible.
      let archivedIDs = state.archivedWorktreeIDSet
      bucket[.archived] = repository.worktrees
        .filter { worktree in
          archivedIDs.contains(worktree.id)
            && state.sidebarItems[id: worktree.id]?.lifecycle == .deletingScript
        }
        .map(\.id)
      buckets[repositoryID] = bucket
    }
    state.sidebarGrouping = SidebarGrouping(bucketsByRepository: buckets)
  }
}

extension RepositoriesFeature.State {
  /// Worktrees in sidebar order, including archived rows so per-row PR / diff /
  /// running-script data survives across archive transitions for views and for
  /// the eventual unarchive.
  fileprivate func orderedWorktreesIncludingArchivedWithRunningDeleteScript(
    in repository: Repository
  ) -> [Worktree] {
    var ordered: [Worktree] = []
    var seen: Set<Worktree.ID> = []
    if let mainWorktree = repository.worktrees.first(where: { isMainWorktree($0) }),
      !isWorktreeArchived(mainWorktree.id),
      seen.insert(mainWorktree.id).inserted
    {
      ordered.append(mainWorktree)
    }
    for worktree in orderedPinnedWorktrees(in: repository) where seen.insert(worktree.id).inserted {
      ordered.append(worktree)
    }
    for worktree in orderedUnpinnedWorktrees(in: repository) where seen.insert(worktree.id).inserted {
      ordered.append(worktree)
    }
    for worktree in repository.worktrees
    where isWorktreeArchived(worktree.id) && seen.insert(worktree.id).inserted {
      ordered.append(worktree)
    }
    return ordered
  }

  /// Resets row lifecycles to `.idle` synchronously so the same-tick reconcile
  /// drops the rows instead of carrying them forward as in-flight. A row action
  /// would target an element removed in the same tick.
  mutating func resetRowLifecycleSyncBeforeReconcile(itemID: SidebarItemFeature.State.ID) {
    sidebarItems[id: itemID]?.lifecycle = .idle
  }

  mutating func resetRowLifecycleSyncBeforeReconcile(inRepositories repositoryIDs: Set<Repository.ID>) {
    for item in sidebarItems where repositoryIDs.contains(item.repositoryID) {
      sidebarItems[id: item.id]?.lifecycle = .idle
    }
  }
}
