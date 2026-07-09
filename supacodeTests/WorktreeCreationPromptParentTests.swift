import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct WorktreeCreationPromptParentTests {
  private let repoID: Repository.ID = "/tmp/create-wt-repo"

  private func makeStateWithPrompt(
    pendingFor branchNames: [String: PendingWorktree.Customization] = [:],
  ) -> RepositoriesFeature.State {
    let mainWorktree = Worktree(
      id: WorktreeID("\(repoID)/main"),
      name: "main",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: repoID.rawValue),
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue),
    )
    let repository = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: repoID.rawValue),
      name: "create-wt-repo",
      worktrees: IdentifiedArray(uniqueElements: [mainWorktree]),
      isGitRepository: true,
    )
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [repository.rootURL]
    state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
      repositoryID: repoID,
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue),
      repositoryName: "create-wt-repo",
      automaticBaseRef: "main",
      defaultBranch: "main",
      remoteNames: [],
      branchMenu: nil,
      branchName: "",
      selectedBaseRef: nil,
      fetchOrigin: false,
      defaultWorktreeBaseDirectory: "/tmp/create-wt-repo/.worktrees",
      validationMessage: nil,
    )
    if !branchNames.isEmpty {
      state.pendingCreationCustomizations[repoID] = branchNames
    }
    return state
  }

  private func makeStore(
    initialState: RepositoriesFeature.State
  ) -> TestStoreOf<RepositoriesFeature> {
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
  }

  @Test func cancelClearsPendingCreationCustomizationsForRepo() async {
    let store = makeStore(
      initialState: makeStateWithPrompt(
        pendingFor: ["feature/x": .init(title: "Test", color: .blue)]
      ))

    await store.send(.worktreeCreationPrompt(.presented(.delegate(.cancel)))) {
      $0.worktreeCreationPrompt = nil
      $0.pendingCreationCustomizations.removeValue(forKey: self.repoID)
    }
  }

  @Test func dismissPreservesPendingCreationCustomizations() async {
    // .dismiss also fires when the parent nils the prompt on the success path.
    let store = makeStore(
      initialState: makeStateWithPrompt(
        pendingFor: ["feature/x": .init(title: "Test", color: .blue)]
      ))

    await store.send(.worktreeCreationPrompt(.dismiss)) {
      $0.worktreeCreationPrompt = nil
    }
  }

  @Test func submitWithoutCustomizationClearsStaleEntryForSameBranch() async {
    let store = makeStore(
      initialState: makeStateWithPrompt(
        pendingFor: ["feature/x": .init(title: "Stale", color: .blue)]
      ))

    await store.send(
      .worktreeCreationPrompt(
        .presented(
          .delegate(
            .submit(
              repositoryID: repoID,
              branchName: "feature/x",
              baseRef: nil,
              fetchOrigin: false,
              placement: WorktreePlacementOverride(name: nil, path: nil),
              title: nil,
              color: nil,
            )
          )))
    ) {
      $0.pendingCreationCustomizations.removeValue(forKey: self.repoID)
    }
  }

  @Test func duplicateValidationFailureDropsPendingCustomization() async {
    let store = makeStore(
      initialState: makeStateWithPrompt(
        pendingFor: ["feature/x": .init(title: "Old", color: .blue)]
      ))

    await store.send(
      .promptedWorktreeCreationChecked(
        repositoryID: repoID,
        branchName: "feature/x",
        baseRef: nil,
        fetchOrigin: false,
        placement: WorktreePlacementOverride(name: nil, path: nil),
        duplicateMessage: "Branch name already exists.",
      )
    ) {
      $0.worktreeCreationPrompt?.isValidating = false
      $0.worktreeCreationPrompt?.validationMessage = "Branch name already exists."
      $0.pendingCreationCustomizations.removeValue(forKey: self.repoID)
    }
  }

  @Test func immediateDuplicateInStartPromptedClearsPendingCustomization() async {
    // First-pass duplicate check (runs before the async branch-list fetch) is a normal
    // prompt-flow rejection. The pending entry must be cleared.
    var state = makeStateWithPrompt(
      pendingFor: ["feature/x": .init(title: "Stale", color: .blue)]
    )
    // Add an existing worktree with the same name so the synchronous check trips.
    let existing = Worktree(
      id: WorktreeID("\(repoID)/feature-x"),
      name: "feature/x",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "\(repoID)/feature-x"),
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue),
    )
    let repo = state.repositories[id: repoID]!
    var worktrees = repo.worktrees
    worktrees.append(existing)
    state.repositories[id: repoID] = Repository(
      id: repo.id,
      rootURL: repo.rootURL,
      name: repo.name,
      worktrees: worktrees,
      isGitRepository: true,
    )
    let store = makeStore(initialState: state)

    await store.send(
      .startPromptedWorktreeCreation(
        repositoryID: repoID,
        branchName: "feature/x",
        baseRef: nil,
        fetchOrigin: false,
        placement: WorktreePlacementOverride(name: nil, path: nil),
      )
    ) {
      $0.worktreeCreationPrompt?.isValidating = false
      $0.worktreeCreationPrompt?.validationMessage = "Branch name already exists."
      $0.pendingCreationCustomizations.removeValue(forKey: self.repoID)
    }
  }

  @Test func createWorktreeForRemovingRepositoryClearsPendingCustomization() async {
    var initial = makeStateWithPrompt(
      pendingFor: ["feature/x": .init(title: "Stale", color: .blue)]
    )
    initial.removingRepositoryIDs[repoID] = RepositoriesFeature.RepositoryRemovalRecord(
      disposition: .gitWorktreeDelete,
      batchID: UUID()
    )
    let store = makeStore(initialState: initial)

    await store.send(
      .createWorktreeInRepository(
        repositoryID: repoID,
        nameSource: .explicit("feature/x"),
        baseRefSource: .explicit(nil),
        fetchOrigin: false,
      )
    ) {
      $0.pendingCreationCustomizations.removeValue(forKey: self.repoID)
    }
  }

  @Test func createWorktreeTransfersCustomizationFromMapToPendingRow() async {
    // Phase-1 → phase-2 transition: when the explicit-name creation begins, the map
    // entry for the branch must move onto the new `PendingWorktree.customization`.
    let store = makeStore(
      initialState: makeStateWithPrompt(
        pendingFor: ["feature/x": .init(title: "Fresh", color: .red)]
      ))

    await store.send(
      .createWorktreeInRepository(
        repositoryID: repoID,
        nameSource: .explicit("feature/x"),
        baseRefSource: .explicit(nil),
        fetchOrigin: false,
      )
    ) {
      $0.pendingCreationCustomizations.removeValue(forKey: self.repoID)
      $0.pendingWorktrees = [
        PendingWorktree(
          id: "pending:00000000-0000-0000-0000-000000000000",
          repositoryID: self.repoID,
          progress: WorktreeCreationProgress(
            stage: .loadingLocalBranches,
            worktreeName: "feature/x"
          ),
          customization: .init(title: "Fresh", color: .red)
        )
      ]
    }
  }

  @Test func reloadThatPrunesPendingRowTransfersCustomizationToDiscoveredWorktree() async {
    let pendingID: Worktree.ID = "pending:test"
    var initial = makeStateWithPrompt()
    initial.pendingWorktrees = [
      PendingWorktree(
        id: pendingID,
        repositoryID: repoID,
        progress: WorktreeCreationProgress(stage: .creatingWorktree, worktreeName: "feature/x"),
        customization: .init(title: "Fresh", color: .red)
      )
    ]
    let createdWorktreeID = WorktreeID("\(repoID)/feature-x")
    let createdWorktree = Worktree(
      id: createdWorktreeID,
      name: "feature/x",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: createdWorktreeID.rawValue),
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue),
    )
    let existingRepository = initial.repositories[id: repoID]!
    var reloadedWorktrees = existingRepository.worktrees
    reloadedWorktrees.append(createdWorktree)
    let reloadedRepository = Repository(
      id: repoID,
      rootURL: existingRepository.rootURL,
      name: existingRepository.name,
      worktrees: reloadedWorktrees,
      isGitRepository: true,
    )
    let store = makeStore(initialState: initial)

    await store.send(
      .repositoriesLoaded(
        [reloadedRepository],
        failures: [],
        roots: [existingRepository.rootURL],
        animated: false
      )
    ) {
      $0.repositories = [reloadedRepository]
      $0.repositoryRoots = [existingRepository.rootURL]
      $0.pendingWorktrees.removeAll()
      $0.isInitialLoadComplete = true
      $0.$sidebar.withLock { sidebar in
        sidebar.insert(
          worktree: createdWorktreeID,
          in: self.repoID,
          bucket: .unpinned,
          item: SidebarState.Item(title: "Fresh", color: .red),
          position: nil,
        )
      }
    }
  }

  @Test func reloadMatchesPendingRowsToDiscoveredWorktreesByName() async {
    // Two concurrent pending creations, only one of the worktrees appears in the reload.
    // The pending row whose `progress.worktreeName` matches the discovered worktree must
    // be the one pruned; the other pending row must survive, and the matched one's
    // customization must be seeded onto the discovered worktree's sidebar item.
    let pendingAID: Worktree.ID = "pending:a"
    let pendingBID: Worktree.ID = "pending:b"
    var initial = makeStateWithPrompt()
    initial.pendingWorktrees = [
      PendingWorktree(
        id: pendingAID,
        repositoryID: repoID,
        progress: WorktreeCreationProgress(stage: .creatingWorktree, worktreeName: "feature/a"),
        customization: .init(title: "Title A", color: .red),
      ),
      PendingWorktree(
        id: pendingBID,
        repositoryID: repoID,
        progress: WorktreeCreationProgress(stage: .creatingWorktree, worktreeName: "feature/b"),
        customization: .init(title: "Title B", color: .blue),
      ),
    ]
    let bWorktreeID = WorktreeID("\(repoID)/feature-b")
    let bWorktree = Worktree(
      id: bWorktreeID,
      name: "feature/b",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: bWorktreeID.rawValue),
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue),
    )
    let existingRepository = initial.repositories[id: repoID]!
    var reloadedWorktrees = existingRepository.worktrees
    reloadedWorktrees.append(bWorktree)
    let reloadedRepository = Repository(
      id: repoID,
      rootURL: existingRepository.rootURL,
      name: existingRepository.name,
      worktrees: reloadedWorktrees,
      isGitRepository: true,
    )
    let store = makeStore(initialState: initial)

    await store.send(
      .repositoriesLoaded(
        [reloadedRepository],
        failures: [],
        roots: [existingRepository.rootURL],
        animated: false,
      )
    ) {
      $0.repositories = [reloadedRepository]
      $0.repositoryRoots = [existingRepository.rootURL]
      // Pending A (no matching discovered worktree) survives; pending B is pruned.
      $0.pendingWorktrees = [
        PendingWorktree(
          id: pendingAID,
          repositoryID: self.repoID,
          progress: WorktreeCreationProgress(stage: .creatingWorktree, worktreeName: "feature/a"),
          customization: .init(title: "Title A", color: .red),
        )
      ]
      $0.isInitialLoadComplete = true
      $0.$sidebar.withLock { sidebar in
        sidebar.insert(
          worktree: bWorktreeID,
          in: self.repoID,
          bucket: .unpinned,
          item: SidebarState.Item(title: "Title B", color: .blue),
          position: nil,
        )
      }
    }
  }

  @Test func successAppliesCustomizationFromPendingRowToSidebar() async {
    let pendingID: Worktree.ID = "pending:test"
    var initial = makeStateWithPrompt()
    initial.pendingWorktrees = [
      PendingWorktree(
        id: pendingID,
        repositoryID: repoID,
        progress: WorktreeCreationProgress(stage: .creatingWorktree, worktreeName: "feature/x"),
        customization: .init(title: "Fresh", color: .red)
      )
    ]
    let createdWorktreeID = WorktreeID("\(repoID)/feature-x")
    let createdWorktree = Worktree(
      id: createdWorktreeID,
      name: "feature/x",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: createdWorktreeID.rawValue),
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue),
    )
    let store = makeStore(initialState: initial)

    await store.send(
      .createRandomWorktreeSucceeded(
        createdWorktree,
        repositoryID: repoID,
        pendingID: pendingID,
      )
    ) {
      $0.pendingWorktrees.removeAll()
      $0.$sidebar.withLock { sidebar in
        sidebar.insert(
          worktree: createdWorktreeID,
          in: self.repoID,
          bucket: .unpinned,
          item: SidebarState.Item(title: "Fresh", color: .red),
          position: nil,
        )
      }
    }
  }

  @Test func submitWithCustomizationOverwritesStaleEntryForSameBranch() async {
    let store = makeStore(
      initialState: makeStateWithPrompt(
        pendingFor: ["feature/x": .init(title: "Stale", color: .blue)]
      ))

    await store.send(
      .worktreeCreationPrompt(
        .presented(
          .delegate(
            .submit(
              repositoryID: repoID,
              branchName: "feature/x",
              baseRef: nil,
              fetchOrigin: false,
              placement: WorktreePlacementOverride(name: nil, path: nil),
              title: "Fresh",
              color: .red,
            )
          )))
    ) {
      $0.pendingCreationCustomizations[self.repoID] = [
        "feature/x": .init(title: "Fresh", color: .red)
      ]
    }
  }
}
