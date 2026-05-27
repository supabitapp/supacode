import ComposableArchitecture
import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct WorktreeCustomizationParentTests {
  private let repoID = "/tmp/customize-wt-repo"
  private let worktreeID = "/tmp/customize-wt-repo/feature-x"

  private func makeInitialState(
    isGitRepository: Bool = true,
    seedSidebarBucket: Bool = true,
  ) -> RepositoriesFeature.State {
    let mainWorktree = Worktree(
      id: "\(repoID)/main",
      name: "main",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: repoID),
      repositoryRootURL: URL(fileURLWithPath: repoID),
    )
    let featureWorktree = Worktree(
      id: worktreeID,
      name: "feature/x",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: worktreeID),
      repositoryRootURL: URL(fileURLWithPath: repoID),
    )
    let repository = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: repoID),
      name: "customize-wt-repo",
      worktrees: IdentifiedArray(uniqueElements: [mainWorktree, featureWorktree]),
      isGitRepository: isGitRepository,
    )
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [repository.rootURL]
    if seedSidebarBucket {
      state.$sidebar.withLock { sidebar in
        sidebar.insert(worktree: self.worktreeID, in: self.repoID, bucket: .unpinned)
      }
    }
    // Pre-build `sidebarItems` so save / cancel tests can assert against an
    // existing per-row state instead of forcing the reducer's `syncSidebar`
    // to materialise rows mid-action and flag the test on unrelated diffs.
    RepositoriesFeature.syncSidebar(&state)
    // Pre-warm the post-reduce caches so the in-reducer recompute is a delta
    // from a populated baseline (matches what every action would see in a
    // real run) rather than a build-from-nil that registers as state churn.
    state.applyPostReduceCacheRecomputes()
    return state
  }

  @Test func requestCustomizeWorktreeSeedsPromptFromStoredItem() async {
    var initial = makeInitialState()
    initial.$sidebar.withLock { sidebar in
      sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.title = "Spicy"
      sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.color = .blue
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeWorktree(worktreeID, repoID)) {
      $0.worktreeCustomization = WorktreeCustomizationFeature.State(
        worktreeID: self.worktreeID,
        repositoryID: self.repoID,
        defaultName: "feature/x",
        title: "Spicy",
        color: .blue,
      )
    }
  }

  @Test func requestCustomizeWorktreeSeedsEmptyPromptWhenNoStoredItem() async {
    let store = TestStore(initialState: makeInitialState(seedSidebarBucket: false)) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeWorktree(worktreeID, repoID)) {
      $0.worktreeCustomization = WorktreeCustomizationFeature.State(
        worktreeID: self.worktreeID,
        repositoryID: self.repoID,
        defaultName: "feature/x",
        title: "",
        color: nil,
      )
    }
  }

  @Test func requestCustomizeWorktreeOpensSheetForFolderSyntheticRow() async {
    // Folder synthetic rows ARE the row the user customizes; they share the worktree path so the
    // per-row title / color the picker writes lands on the visible folder row.
    let store = TestStore(
      initialState: makeInitialState(isGitRepository: false, seedSidebarBucket: false)
    ) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeWorktree(worktreeID, repoID)) {
      $0.worktreeCustomization = WorktreeCustomizationFeature.State(
        worktreeID: self.worktreeID,
        repositoryID: self.repoID,
        defaultName: "customize-wt-repo",
        title: "",
        color: nil,
      )
    }
  }

  @Test func requestCustomizeWorktreeNoOpsForMainWorktrees() async {
    // The context menu hides the entry for the main worktree row, but a future palette /
    // deeplink could still route here. The reducer guard is the backstop.
    let store = TestStore(initialState: makeInitialState(seedSidebarBucket: false)) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeWorktree("\(repoID)/main", repoID))
    #expect(store.state.worktreeCustomization == nil)
  }

  @Test func saveDelegatePersistsTitleAndColorToBucketedItem() async {
    var initial = makeInitialState()
    initial.worktreeCustomization = WorktreeCustomizationFeature.State(
      worktreeID: worktreeID,
      repositoryID: repoID,
      defaultName: "feature/x",
      title: "",
      color: nil,
    )
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(
      .worktreeCustomization(
        .presented(
          .delegate(
            .save(
              worktreeID: worktreeID,
              repositoryID: repoID,
              title: "Renamed",
              color: .red,
            )
          )))
    ) {
      $0.worktreeCustomization = nil
      $0.$sidebar.withLock { sidebar in
        sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.title =
          "Renamed"
        sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.color = .red
      }
      // syncSidebar fans the bucketed Item write into the per-row mirror.
      $0.sidebarItems[id: self.worktreeID]?.customTitle = "Renamed"
      $0.sidebarItems[id: self.worktreeID]?.customTint = .red
      // The save action invalidates every cache; mirror the post-reduce hook
      // so the test diff only contains intentional state changes.
      $0.applyPostReduceCacheRecomputes()
    }
  }

  @Test func saveDelegateRefreshesSelectedWorktreeSlice() async {
    var initial = makeInitialState()
    initial.setSingleWorktreeSelection(worktreeID)
    initial.applyPostReduceCacheRecomputes(.selectedWorktreeSlice)
    initial.worktreeCustomization = WorktreeCustomizationFeature.State(
      worktreeID: worktreeID,
      repositoryID: repoID,
      defaultName: "feature/x",
      title: "",
      color: nil,
    )
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(
      .worktreeCustomization(
        .presented(
          .delegate(
            .save(
              worktreeID: worktreeID,
              repositoryID: repoID,
              title: "Renamed",
              color: .red,
            )
          )))
    ) {
      $0.worktreeCustomization = nil
      $0.$sidebar.withLock { sidebar in
        sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.title =
          "Renamed"
        sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.color = .red
      }
      $0.sidebarItems[id: self.worktreeID]?.customTitle = "Renamed"
      $0.sidebarItems[id: self.worktreeID]?.customTint = .red
      $0.applyPostReduceCacheRecomputes()
    }
    #expect(store.state.selectedWorktreeSlice?.resolvedSidebarTitle == "Renamed")
    #expect(store.state.selectedWorktreeSlice?.customTint == .red)
  }

  @Test func pinWorktreePreservesCustomTitleAndColor() async {
    var initial = makeInitialState()
    initial.$sidebar.withLock { sidebar in
      sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.title =
        "Renamed"
      sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.color = .red
    }
    RepositoriesFeature.syncSidebar(&initial)
    initial.applyPostReduceCacheRecomputes()
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.pinWorktree(worktreeID))

    #expect(store.state.sidebar.sections[repoID]?.buckets[.unpinned]?.items[worktreeID] == nil)
    #expect(store.state.sidebar.sections[repoID]?.buckets[.pinned]?.items[worktreeID]?.title == "Renamed")
    #expect(store.state.sidebar.sections[repoID]?.buckets[.pinned]?.items[worktreeID]?.color == .red)
    #expect(store.state.sidebarItems[id: worktreeID]?.customTitle == "Renamed")
    #expect(store.state.sidebarItems[id: worktreeID]?.customTint == .red)
  }

  @Test func unpinWorktreePreservesCustomTitleAndColor() async {
    var initial = makeInitialState(seedSidebarBucket: false)
    initial.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: self.worktreeID,
        in: self.repoID,
        bucket: .pinned,
        item: .init(title: "Renamed", color: .red)
      )
    }
    RepositoriesFeature.syncSidebar(&initial)
    initial.applyPostReduceCacheRecomputes()
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.unpinWorktree(worktreeID))

    #expect(store.state.sidebar.sections[repoID]?.buckets[.pinned]?.items[worktreeID] == nil)
    #expect(store.state.sidebar.sections[repoID]?.buckets[.unpinned]?.items[worktreeID]?.title == "Renamed")
    #expect(store.state.sidebar.sections[repoID]?.buckets[.unpinned]?.items[worktreeID]?.color == .red)
    #expect(store.state.sidebarItems[id: worktreeID]?.customTitle == "Renamed")
    #expect(store.state.sidebarItems[id: worktreeID]?.customTint == .red)
  }

  @Test func unpinWorktreePrefersPinnedPayloadOverStaleUnpinnedSibling() async {
    // Defensive coverage for a corrupted double-bucket pre-state (hand-edit,
    // migrator race) where the same row exists in both `.pinned` and
    // `.unpinned` with different payloads. The pinned entry is the live
    // row the user sees; unpin must carry its `title` / `color` forward,
    // not the stale unpinned sibling's.
    var initial = makeInitialState(seedSidebarBucket: false)
    initial.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: self.worktreeID,
        in: self.repoID,
        bucket: .pinned,
        item: .init(title: "Live", color: .red)
      )
      sidebar.insert(
        worktree: self.worktreeID,
        in: self.repoID,
        bucket: .unpinned,
        item: .init(title: "Stale", color: .blue)
      )
    }
    RepositoriesFeature.syncSidebar(&initial)
    initial.applyPostReduceCacheRecomputes()
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.unpinWorktree(worktreeID))

    #expect(store.state.sidebar.sections[repoID]?.buckets[.pinned]?.items[worktreeID] == nil)
    #expect(store.state.sidebar.sections[repoID]?.buckets[.unpinned]?.items[worktreeID]?.title == "Live")
    #expect(store.state.sidebar.sections[repoID]?.buckets[.unpinned]?.items[worktreeID]?.color == .red)
  }

  @Test func pinWorktreePrefersUnpinnedPayloadOverStalePinnedSibling() async {
    // Symmetric to the unpin case: when the same row appears in both buckets, `.unpinned` is the
    // logical source for a pin, so its payload (not a stale `.pinned` sibling's) must round-trip.
    var initial = makeInitialState(seedSidebarBucket: false)
    initial.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: self.worktreeID,
        in: self.repoID,
        bucket: .unpinned,
        item: .init(title: "Live", color: .red)
      )
      sidebar.insert(
        worktree: self.worktreeID,
        in: self.repoID,
        bucket: .pinned,
        item: .init(title: "Stale", color: .blue)
      )
    }
    RepositoriesFeature.syncSidebar(&initial)
    initial.applyPostReduceCacheRecomputes()
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.pinWorktree(worktreeID))

    #expect(store.state.sidebar.sections[repoID]?.buckets[.unpinned]?.items[worktreeID] == nil)
    #expect(store.state.sidebar.sections[repoID]?.buckets[.pinned]?.items[worktreeID]?.title == "Live")
    #expect(store.state.sidebar.sections[repoID]?.buckets[.pinned]?.items[worktreeID]?.color == .red)
  }

  @Test func cancelDelegateClearsPresentedState() async {
    var initial = makeInitialState()
    initial.worktreeCustomization = WorktreeCustomizationFeature.State(
      worktreeID: worktreeID,
      repositoryID: repoID,
      defaultName: "feature/x",
      title: "",
      color: nil,
    )
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(
      .worktreeCustomization(.presented(.delegate(.cancel)))
    ) {
      $0.worktreeCustomization = nil
    }
  }
}
