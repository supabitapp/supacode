import ComposableArchitecture
import Foundation
import Testing

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
  /// The open-action bits are not mirrored here: they dispatch the
  /// `.resolveOpenActions` effect, which the TestStore drives on its own.
  @MainActor
  mutating func applyPostReduceCacheRecomputes(_ invalidations: CacheInvalidations = .all) {
    applyCacheRecomputes(invalidations)
    expectCachesConverged()
  }

  /// The invariant the `CacheInvalidations` switch exists to uphold: once an arm
  /// has run with its declared bits, recomputing every pure cache must be a
  /// no-op. An exhaustive switch only forces a new action to be *listed*, not
  /// classified, so assert sufficiency here, on every action the suite sends.
  ///
  /// `openActionByRepositoryID` is out of scope: it is not recomputed from state
  /// but resolved off disk in an effect, and the TestStore already forces every
  /// arm that must re-arm it to declare the `.resolveOpenActions` it sends.
  @MainActor
  private mutating func expectCachesConverged() {
    let structure = sidebarStructure
    let selectionSlice = sidebarSelectionSlice
    let selectedSlice = selectedWorktreeSlice
    let notificationGroups = toolbarNotificationGroupsCache
    let menuBarSections = menuBarSectionsCache

    applyCacheRecomputes(.allSidebar)

    let message = "Declared CacheInvalidations were insufficient: a full recompute changed"
    #expect(sidebarStructure == structure, "\(message) sidebarStructure.")
    #expect(sidebarSelectionSlice == selectionSlice, "\(message) sidebarSelectionSlice.")
    #expect(selectedWorktreeSlice == selectedSlice, "\(message) selectedWorktreeSlice.")
    #expect(toolbarNotificationGroupsCache == notificationGroups, "\(message) toolbarNotificationGroupsCache.")
    #expect(menuBarSectionsCache == menuBarSections, "\(message) menuBarSectionsCache.")

    // Restore, so a shortfall surfaces as this assertion rather than as an
    // unrelated TestStore diff in every test that sends the offending action.
    sidebarStructure = structure
    sidebarSelectionSlice = selectionSlice
    selectedWorktreeSlice = selectedSlice
    toolbarNotificationGroupsCache = notificationGroups
    menuBarSectionsCache = menuBarSections
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
