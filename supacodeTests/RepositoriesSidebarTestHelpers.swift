import ComposableArchitecture
import Foundation

@testable import supacode

extension RepositoriesFeature.State {
  /// Test mirror of `syncSidebar`.
  @MainActor
  mutating func reconcileSidebarForTesting() {
    RepositoriesFeature.syncSidebar(&self)
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
