import ComposableArchitecture
import Foundation
import OrderedCollections
import SupacodeSettingsShared

extension RepositoriesFeature {
  /// Reconciles per-row data after any aggregate mutation.
  static func syncSidebar(_ state: inout State) {
    reconcileSidebarItems(&state)
    rebuildSidebarGrouping(&state)
  }

  /// Rebuilds `state.sidebarItems` from the canonical roster, preserving per-row data on surviving ids.
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
        let lifecycle = state.sidebarItemLifecycle(for: id, repositoryID: repository.id)

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
            accent: nil,
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
        item.lifecycle = lifecycle
        // Clear the PR query branch when the worktree was renamed.
        if let existing, existing.branchName != worktree.name {
          item.pullRequestBranchAtQueryTime = nil
        }
        let infoEntry = state.worktreeInfos[id: id]
        item.addedLines = infoEntry?.addedLines
        item.removedLines = infoEntry?.removedLines
        item.pullRequest = infoEntry?.pullRequest
        // Dictionary iteration is hash-seed-dependent; sort by id for deterministic Equatable.
        let runningTints = state.runningScriptsByWorktreeID[id] ?? [:]
        item.runningScripts = IdentifiedArrayOf(
          uniqueElements:
            runningTints
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { SidebarItemFeature.State.RunningScript(id: $0.key, tint: $0.value) }
        )
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
            accent: nil,
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

      var unpinned = state.orderedUnpinnedWorktreeIDs(in: repository)
      for pending in state.pendingWorktrees where pending.repositoryID == repositoryID {
        unpinned.append(pending.id)
      }
      bucket[.unpinned] = unpinned
      // Archived bucket: only worktrees whose delete script is running stay visible.
      let archivedIDs = state.archivedWorktreeIDSet
      bucket[.archived] = repository.worktrees
        .filter { archivedIDs.contains($0.id) && state.deleteScriptWorktreeIDs.contains($0.id) }
        .map(\.id)
      buckets[repositoryID] = bucket
    }
    state.sidebarGrouping = SidebarGrouping(bucketsByRepository: buckets)
  }
}

extension RepositoriesFeature.State {
  /// Collapses the aggregated lifecycle sets into the per-row `Lifecycle`.
  fileprivate func sidebarItemLifecycle(
    for worktreeID: Worktree.ID,
    repositoryID: Repository.ID
  ) -> SidebarItemFeature.State.Lifecycle {
    if deleteScriptWorktreeIDs.contains(worktreeID) {
      return .deletingScript
    }
    if removingRepositoryIDs[repositoryID] != nil || deletingWorktreeIDs.contains(worktreeID) {
      return .deleting
    }
    if archivingWorktreeIDs.contains(worktreeID) {
      return .archiving
    }
    if pendingSetupScriptWorktreeIDs.contains(worktreeID) {
      return .pending
    }
    return .idle
  }

  /// Worktrees in sidebar order, including archived rows with a running delete script.
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
    let archived = archivedWorktreeIDSet
    for worktree in repository.worktrees
    where archived.contains(worktree.id)
      && deleteScriptWorktreeIDs.contains(worktree.id)
      && seen.insert(worktree.id).inserted
    {
      ordered.append(worktree)
    }
    return ordered
  }
}
