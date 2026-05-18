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

  @Test func requestCustomizeWorktreeNoOpsForFolderRepos() async {
    let store = TestStore(
      initialState: makeInitialState(isGitRepository: false, seedSidebarBucket: false)
    ) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeWorktree(worktreeID, repoID))
    // No state mutation expected — `worktreeCustomization` stays nil.
  }

  @Test func requestCustomizeWorktreeNoOpsForMainWorktrees() async {
    // The context menu hides the entry for the main worktree row, but a future
    // palette / deeplink could still route here — the reducer guard is the
    // backstop so customization can't be written for a row that won't render it.
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
