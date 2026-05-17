import ComposableArchitecture
import Foundation

@testable import supacode

extension RepositoriesFeature.State {
  /// Test mirror of the full sidebar pipeline: `syncSidebar` (matching
  /// reducer-body handlers that explicitly resync) + the structure recompute
  /// the post-reduce hook would run. `$0.reconcileSidebarForTesting()` in a
  /// TestStore expectation covers both in one call so tests don't have to
  /// remember to mirror each piece separately.
  @MainActor
  mutating func reconcileSidebarForTesting() {
    RepositoriesFeature.syncSidebar(&self)
    recomputeSidebarStructureIfChanged()
  }

  /// Convenience init for tests that need a populated row/grouping store from a roster.
  @MainActor
  init(reconciledRepositories repositories: [Repository]) {
    self.init()
    self.repositories = IdentifiedArray(uniqueElements: repositories)
    self.repositoryRoots = repositories.map(\.rootURL)
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
