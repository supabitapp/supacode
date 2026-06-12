import ComposableArchitecture
import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared
import SwiftUI
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct RepositoriesFeatureRenameBranchTests {
  private let repoID: RepositoryID = "/tmp/rename-repo"

  private func makeInitialState(
    worktreeName: String = "feature/old",
    isGitRepository: Bool = true,
    isMissing: Bool = false,
    isAttached: Bool = true
  ) -> RepositoriesFeature.State {
    let mainWorktree = Worktree(
      id: WorktreeID("\(repoID)/main"),
      name: "main",
      detail: "main",
      workingDirectory: URL(fileURLWithPath: repoID.rawValue),
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue),
      isMissing: false
    )
    let worktree = Worktree(
      id: WorktreeID("\(repoID)/feature-old"),
      name: worktreeName,
      detail: "feature-old",
      workingDirectory: URL(fileURLWithPath: "\(repoID)/feature-old"),
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue),
      isMissing: isMissing,
      isAttached: isAttached
    )
    let repository = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: repoID.rawValue),
      name: "rename-repo",
      worktrees: IdentifiedArray(uniqueElements: [mainWorktree, worktree]),
      isGitRepository: isGitRepository
    )
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [repository.rootURL]
    state.reconcileSidebarForTesting()
    return state
  }

  @Test func requestRenameBranchSeedsPromptFromWorktree() async {
    let store = TestStore(initialState: makeInitialState()) {
      RepositoriesFeature()
    }

    await store.send(.requestRenameBranch(WorktreeID("\(repoID)/feature-old"), repoID)) {
      $0.renameBranchPrompt = RenameBranchFeature.State(
        worktreeID: WorktreeID("\(self.repoID)/feature-old"),
        repositoryID: self.repoID,
        repositoryRootURL: URL(fileURLWithPath: self.repoID.rawValue),
        currentName: "feature/old"
      )
    }
  }

  @Test func requestRenameBranchNoOpsForFolderRepo() async {
    let store = TestStore(initialState: makeInitialState(isGitRepository: false)) {
      RepositoriesFeature()
    }
    await store.send(.requestRenameBranch(WorktreeID("\(repoID)/feature-old"), repoID))
  }

  @Test func requestRenameBranchNoOpsForMissingWorktree() async {
    let store = TestStore(initialState: makeInitialState(isMissing: true)) {
      RepositoriesFeature()
    }
    await store.send(.requestRenameBranch(WorktreeID("\(repoID)/feature-old"), repoID))
  }

  @Test func requestRenameBranchSeedsPromptForMainWorktree() async {
    let store = TestStore(initialState: makeInitialState()) {
      RepositoriesFeature()
    }
    await store.send(.requestRenameBranch(WorktreeID("\(repoID)/main"), repoID)) {
      $0.renameBranchPrompt = RenameBranchFeature.State(
        worktreeID: WorktreeID("\(self.repoID)/main"),
        repositoryID: self.repoID,
        repositoryRootURL: URL(fileURLWithPath: self.repoID.rawValue),
        currentName: "main"
      )
    }
  }

  @Test func renamedDelegateUpdatesWorktreeAndDispatchesScopedPullRequestRefresh() async {
    var initial = makeInitialState()
    initial.renameBranchPrompt = RenameBranchFeature.State(
      worktreeID: WorktreeID("\(repoID)/feature-old"),
      repositoryID: repoID,
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue),
      currentName: "feature/old"
    )
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(
      .renameBranchPrompt(
        .presented(
          .delegate(
            .renamed(
              worktreeID: WorktreeID("\(repoID)/feature-old"),
              repositoryID: repoID,
              newName: "feature/new"
            )
          )
        )
      )
    ) {
      $0.renameBranchPrompt = nil
      $0.updateWorktreeName(WorktreeID("\(self.repoID)/feature-old"), name: "feature/new")
    }

    await store.receive(\.worktreeInfoEvent)

    // Lock the cache rebuild: the renamed row's `name` must propagate to the
    // sidebar item and the structure cache, not just the underlying Worktree.
    #expect(
      store.state.repositories[id: repoID]?
        .worktrees[id: WorktreeID("\(repoID)/feature-old")]?.name == "feature/new"
    )
    #expect(store.state.sidebarItems[id: WorktreeID("\(repoID)/feature-old")]?.name == "feature/new")
    #expect(store.state.sidebarItems[id: WorktreeID("\(repoID)/feature-old")]?.branchName == "feature/new")
  }

  @Test func lifecyclePendingDoesNotCloseRenameSheet() async {
    var initial = makeInitialState()
    initial.renameBranchPrompt = RenameBranchFeature.State(
      worktreeID: WorktreeID("\(repoID)/feature-old"),
      repositoryID: repoID,
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue),
      currentName: "feature/old"
    )
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(
      .sidebarItems(
        .element(id: WorktreeID("\(repoID)/feature-old"), action: .lifecycleChanged(.pending))
      )
    )
    #expect(store.state.renameBranchPrompt != nil)
  }

  @Test func requestRenameBranchNoOpsForDetachedHeadWorktree() async {
    let store = TestStore(initialState: makeInitialState(isAttached: false)) {
      RepositoriesFeature()
    }
    await store.send(.requestRenameBranch(WorktreeID("\(repoID)/feature-old"), repoID))
  }

  @Test func requestRenameBranchNoOpsForNonexistentRepository() async {
    let store = TestStore(initialState: makeInitialState()) {
      RepositoriesFeature()
    }
    await store.send(.requestRenameBranch(WorktreeID("\(repoID)/feature-old"), "/does/not/exist"))
  }

  @Test func requestRenameBranchNoOpsWhenRowIsNotIdle() async {
    var initial = makeInitialState()
    initial.sidebarItems[id: WorktreeID("\(repoID)/feature-old")]?.lifecycle = .archiving
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    await store.send(.requestRenameBranch(WorktreeID("\(repoID)/feature-old"), repoID))
  }

  @Test func lifecycleFlipClosesRenameSheet() async {
    var initial = makeInitialState()
    initial.renameBranchPrompt = RenameBranchFeature.State(
      worktreeID: WorktreeID("\(repoID)/feature-old"),
      repositoryID: repoID,
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue),
      currentName: "feature/old"
    )
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(
      .sidebarItems(
        .element(id: WorktreeID("\(repoID)/feature-old"), action: .lifecycleChanged(.archiving))
      )
    ) {
      $0.renameBranchPrompt = nil
    }
  }

  @Test func cancelDelegateClearsPresentedState() async {
    var initial = makeInitialState()
    initial.renameBranchPrompt = RenameBranchFeature.State(
      worktreeID: WorktreeID("\(repoID)/feature-old"),
      repositoryID: repoID,
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue),
      currentName: "feature/old"
    )
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.renameBranchPrompt(.presented(.delegate(.cancel)))) {
      $0.renameBranchPrompt = nil
    }
  }
}
