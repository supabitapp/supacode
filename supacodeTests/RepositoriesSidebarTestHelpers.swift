import ComposableArchitecture
import Foundation

@testable import supacode

extension AppFeature.State {
  /// Mirrors AppFeature's post-reduce hook for TestStore expectations.
  /// Equatable diff inside the helper keeps no-op writes from invalidating
  /// the menu-bar `WorktreeCommands` snapshot.
  @MainActor
  mutating func applyPostReduceCacheRecomputes() {
    recomputeWorktreeMenuSnapshotIfChanged()
  }
}

extension RepositoriesFeature.State {
  /// Test mirror of the full sidebar pipeline: `syncSidebar` (matching
  /// reducer-body handlers that explicitly resync) + every cache recompute the
  /// post-reduce hook would run. Use this when the action explicitly resyncs.
  @MainActor
  mutating func reconcileSidebarForTesting() {
    RepositoriesFeature.syncSidebar(&self)
    applyPostReduceCacheRecomputes()
  }

  /// Mirrors the post-reduce hook for TestStore expectations. Pass the same
  /// `CacheInvalidations` set the action's `cacheInvalidations` returns so the
  /// expected state mutates exactly what the live reducer does, no more.
  @MainActor
  mutating func applyPostReduceCacheRecomputes(_ invalidations: CacheInvalidations = .all) {
    applyCacheRecomputes(invalidations)
  }

  /// Convenience init for tests that need a populated row/grouping store from a roster.
  @MainActor
  init(reconciledRepositories repositories: [Repository]) {
    self.init()
    self.repositories = IdentifiedArray(uniqueElements: repositories)
    // Remote repos persist via the connections store, never `repositoryRoots`;
    // only local roots belong here, matching production.
    self.repositoryRoots = repositories.filter { $0.host == nil }.map(\.rootURL)
    reconcileSidebarForTesting()
  }

  /// Seed per-row pull-request data for tests directly on the row store.
  @MainActor
  mutating func setWorktreeInfoForTesting(
    id: Worktree.ID,
    addedLines: Int? = nil,
    removedLines: Int? = nil,
    pullRequest: GithubPullRequest? = nil
  ) {
    sidebarItems[id: id]?.addedLines = addedLines
    sidebarItems[id: id]?.removedLines = removedLines
    sidebarItems[id: id]?.pullRequest = pullRequest
  }
}
