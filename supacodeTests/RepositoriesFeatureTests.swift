import Clocks
import ComposableArchitecture
import CustomDump
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import supacode

@MainActor
struct RepositoriesFeatureTests {
  @Test func refreshWorktreesSetsRefreshingStateUntilLoadCompletes() async {
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.worktrees = { _ in [worktree] }
    }

    await store.send(.refreshWorktrees) {
      $0.isRefreshingWorktrees = true
    }
    await store.receive(\.reloadRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.isRefreshingWorktrees = false
      $0.isInitialLoadComplete = true
    }
  }

  @Test func refreshWorktreesWithoutRootsStopsRefreshingImmediately() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }

    await store.send(.refreshWorktrees) {
      $0.isRefreshingWorktrees = true
    }
    await store.receive(\.reloadRepositories) {
      $0.isRefreshingWorktrees = false
    }
  }

  @Test func repositoriesLoadedClearsRefreshingState() async {
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.isRefreshingWorktrees = true
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [repository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.isRefreshingWorktrees = false
      $0.isInitialLoadComplete = true
    }
  }

  @Test func selectWorktreeSendsDelegate() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "fox")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.selectWorktree(worktree.id)) {
      $0.selection = .worktree(worktree.id)
      $0.sidebarSelectedWorktreeIDs = [worktree.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectWorktreeCollapsesSidebarSelectedWorktreeIDs() async {
    let wt1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let wt2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: "/tmp/repo")
    let wt3 = makeWorktree(id: "/tmp/repo/wt3", name: "wt3", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2, wt3])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(wt1.id)
    initialState.sidebarSelectedWorktreeIDs = [wt1.id, wt2.id, wt3.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.selectWorktree(wt2.id)) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func setSidebarSelectedWorktreeIDsKeepsSelectedAndPrunesUnknown() async {
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree1, worktree2])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree1.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .setSidebarSelectedWorktreeIDs(
        [worktree2.id, "/tmp/repo/unknown"]
      )
    ) {
      $0.sidebarSelectedWorktreeIDs = [worktree1.id, worktree2.id]
    }
  }

  @Test func selectArchivedWorktreesClearsSidebarSelectedWorktreeIDs() async {
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree1, worktree2])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree1.id)
    initialState.sidebarSelectedWorktreeIDs = [worktree1.id, worktree2.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.selectArchivedWorktrees) {
      $0.selection = .archivedWorktrees
      $0.sidebarSelectedWorktreeIDs = []
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func createRandomWorktreeWithoutRepositoriesShowsAlert() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Open a repository to create a worktree.")
    }

    await store.send(.createRandomWorktree) {
      $0.alert = expectedAlert
    }
  }

  @Test func createRandomWorktreeInRepositoryWithPromptEnabledPresentsPrompt() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.branchRefs = { _ in ["origin/main", "origin/dev"] }
    }

    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.promptedWorktreeCreationDataLoaded) {
      $0.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
        repositoryID: repository.id,
        repositoryName: repository.name,
        automaticBaseRefLabel: "Automatic (origin/main)",
        baseRefOptions: ["origin/dev", "origin/main"],
        branchName: "",
        selectedBaseRef: nil,
        validationMessage: nil
      )
    }
  }

  @Test func promptedWorktreeCreationCancelDismissesPrompt() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
      repositoryID: repository.id,
      repositoryName: repository.name,
      automaticBaseRefLabel: "Automatic (origin/main)",
      baseRefOptions: ["origin/main"],
      branchName: "feature/new-branch",
      selectedBaseRef: nil,
      validationMessage: nil
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeCreationPrompt(.presented(.delegate(.cancel)))) {
      $0.worktreeCreationPrompt = nil
    }
  }

  @Test func startPromptedWorktreeCreationWithDuplicateLocalBranchShowsValidation() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
      repositoryID: repository.id,
      repositoryName: repository.name,
      automaticBaseRefLabel: "Automatic (origin/main)",
      baseRefOptions: ["origin/main"],
      branchName: "feature/existing",
      selectedBaseRef: nil,
      validationMessage: nil
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.localBranchNames = { _ in ["feature/existing"] }
    }

    await store.send(
      .startPromptedWorktreeCreation(
        repositoryID: repository.id,
        branchName: "feature/existing",
        baseRef: nil
      )
    ) {
      $0.worktreeCreationPrompt?.validationMessage = nil
      $0.worktreeCreationPrompt?.isValidating = true
    }
    await store.receive(\.promptedWorktreeCreationChecked) {
      $0.worktreeCreationPrompt?.validationMessage = "Branch name already exists."
      $0.worktreeCreationPrompt?.isValidating = false
    }
  }

  @Test func createRandomWorktreeInRepositoryLatestPromptRequestWins() async {
    actor PromptLoadGate {
      var continuation: CheckedContinuation<Void, Never>?

      func wait() async {
        await withCheckedContinuation { continuation in
          self.continuation = continuation
        }
      }

      func waitUntilArmed() async {
        while continuation == nil {
          await Task.yield()
        }
      }

      func resume() {
        continuation?.resume()
        continuation = nil
      }
    }

    let repoRootA = "/tmp/repo-a"
    let repoRootB = "/tmp/repo-b"
    let promptLoadGate = PromptLoadGate()
    let repoA = makeRepository(
      id: repoRootA,
      worktrees: [makeWorktree(id: repoRootA, name: "main", repoRoot: repoRootA)]
    )
    let repoB = makeRepository(
      id: repoRootB,
      worktrees: [makeWorktree(id: repoRootB, name: "main", repoRoot: repoRootB)]
    )
    let store = TestStore(initialState: makeState(repositories: [repoA, repoB])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.automaticWorktreeBaseRef = { root in
        if root.path(percentEncoded: false) == repoRootA {
          await promptLoadGate.wait()
        }
        return "origin/main"
      }
      $0.gitClient.branchRefs = { _ in ["origin/main"] }
    }

    await store.send(.createRandomWorktreeInRepository(repoA.id))
    await promptLoadGate.waitUntilArmed()
    await store.send(.createRandomWorktreeInRepository(repoB.id))
    await promptLoadGate.resume()
    await store.receive(\.promptedWorktreeCreationDataLoaded) {
      $0.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
        repositoryID: repoB.id,
        repositoryName: repoB.name,
        automaticBaseRefLabel: "Automatic (origin/main)",
        baseRefOptions: ["origin/main"],
        branchName: "",
        selectedBaseRef: nil,
        validationMessage: nil
      )
    }
    await store.finish()
  }

  @Test func promptedWorktreeCreationCancelDuringValidationStopsCreation() async {
    let validationClock = TestClock()
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
      repositoryID: repository.id,
      repositoryName: repository.name,
      automaticBaseRefLabel: "Automatic (origin/main)",
      baseRefOptions: ["origin/main"],
      branchName: "feature/new-branch",
      selectedBaseRef: nil,
      validationMessage: nil
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.localBranchNames = { _ in
        try? await validationClock.sleep(for: .seconds(1))
        return []
      }
    }

    await store.send(
      .startPromptedWorktreeCreation(
        repositoryID: repository.id,
        branchName: "feature/new-branch",
        baseRef: nil
      )
    ) {
      $0.worktreeCreationPrompt?.validationMessage = nil
      $0.worktreeCreationPrompt?.isValidating = true
    }
    await store.send(.worktreeCreationPrompt(.presented(.delegate(.cancel)))) {
      $0.worktreeCreationPrompt = nil
    }
    await validationClock.advance(by: .seconds(1))
    await store.finish()
  }

  @Test func createWorktreeInRepositoryWithInvalidBranchNameFails() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.isValidBranchName = { _, _ in false }
      $0.gitClient.localBranchNames = { _ in [] }
    }
    store.exhaustivity = .off

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Branch name invalid")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Enter a valid git branch name and try again.")
    }

    await store.send(
      .createWorktreeInRepository(
        repositoryID: repository.id,
        nameSource: .explicit("../../Desktop"),
        baseRefSource: .repositorySetting
      )
    )
    await store.receive(\.createRandomWorktreeFailed) {
      $0.alert = expectedAlert
    }
    #expect(store.state.pendingWorktrees.isEmpty)
    await store.finish()
  }

  @Test func createRandomWorktreeFailedWithTraversalNameSkipsCleanup() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let removed = LockIsolated(false)
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { _, _ in
        removed.withValue { $0 = true }
        return URL(fileURLWithPath: "/tmp/removed")
      }
      $0.gitClient.pruneWorktrees = { _ in }
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("boom")
    }

    await store.send(
      .createRandomWorktreeFailed(
        title: "Unable to create worktree",
        message: "boom",
        pendingID: "pending:1",
        previousSelection: nil,
        repositoryID: repository.id,
        name: "../../Desktop",
        baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees")
      )
    ) {
      $0.alert = expectedAlert
    }
    await store.finish()
    #expect(removed.value == false)
  }

  @Test(.dependencies) func createRandomWorktreeInRepositoryStreamsOutputLines() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot
    )
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.promptForWorktreeCreation = false }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 2 }
      $0.gitClient.untrackedFileCount = { _ in 1 }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.outputLine(ShellStreamLine(source: .stderr, text: "[1/2] copy .env")))
          continuation.yield(.outputLine(ShellStreamLine(source: .stderr, text: "[2/2] copy .cache")))
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.createRandomWorktreeSucceeded)
    await store.finish()

    #expect(store.state.pendingWorktrees.isEmpty)
    #expect(store.state.selection == .worktree(createdWorktree.id))
    #expect(store.state.sidebarSelectedWorktreeIDs == [createdWorktree.id])
    #expect(store.state.pendingSetupScriptWorktreeIDs.contains(createdWorktree.id))
    #expect(store.state.pendingTerminalFocusWorktreeIDs.contains(createdWorktree.id))
    #expect(store.state.repositories[id: repository.id]?.worktrees[id: createdWorktree.id] != nil)
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func createRandomWorktreeUsesRepositoryWorktreeBaseDirectoryOverride() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot
    )
    let observedBaseDirectory = LockIsolated<URL?>(nil)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.defaultWorktreeBaseDirectoryPath = "/tmp/global-worktrees"
    }
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.worktreeBaseDirectoryPath = "/tmp/repo-override"
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.createWorktreeStream = { _, _, baseDirectory, _, _, _ in
        observedBaseDirectory.withValue { $0 = baseDirectory }
        return AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.createRandomWorktreeSucceeded)
    await store.finish()

    let expectedBaseDirectory = SupacodePaths.worktreeBaseDirectory(
      for: repository.rootURL,
      globalDefaultPath: "/tmp/global-worktrees",
      repositoryOverridePath: "/tmp/repo-override"
    )
    #expect(observedBaseDirectory.value == expectedBaseDirectory)
  }

  @Test(.dependencies) func createRandomWorktreeUsesGlobalWorktreeBaseDirectoryWhenRepositoryOverrideMissing() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot
    )
    let observedBaseDirectory = LockIsolated<URL?>(nil)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.defaultWorktreeBaseDirectoryPath = "/tmp/global-worktrees"
    }
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.worktreeBaseDirectoryPath = nil
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.createWorktreeStream = { _, _, baseDirectory, _, _, _ in
        observedBaseDirectory.withValue { $0 = baseDirectory }
        return AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.createRandomWorktreeSucceeded)
    await store.finish()

    let expectedBaseDirectory = SupacodePaths.worktreeBaseDirectory(
      for: repository.rootURL,
      globalDefaultPath: "/tmp/global-worktrees",
      repositoryOverridePath: nil
    )
    #expect(observedBaseDirectory.value == expectedBaseDirectory)
  }

  @Test(.dependencies) func createRandomWorktreeInRepositoryStreamFailureRemovesPendingWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.promptForWorktreeCreation = false }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 2 }
      $0.gitClient.untrackedFileCount = { _ in 1 }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.outputLine(ShellStreamLine(source: .stderr, text: "[1/2] copy .env")))
          continuation.finish(throwing: GitClientError.commandFailed(command: "wt sw", message: "boom"))
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.createRandomWorktreeFailed)
    await store.finish()

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Git command failed: wt sw\nboom")
    }

    #expect(store.state.pendingWorktrees.isEmpty)
    #expect(store.state.selection == nil)
    #expect(store.state.alert == expectedAlert)
    #expect(store.state.repositories[id: repository.id]?.worktrees[id: mainWorktree.id] != nil)
  }

  @Test(.dependencies) func createRandomWorktreeFailureUsesProvidedBaseDirectoryForCleanup() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createTimeBaseDirectory = SupacodePaths.worktreeBaseDirectory(
      for: repository.rootURL,
      globalDefaultPath: "/tmp/worktrees-original",
      repositoryOverridePath: nil
    )
    let changedBaseDirectory = SupacodePaths.worktreeBaseDirectory(
      for: repository.rootURL,
      globalDefaultPath: "/tmp/worktrees-changed",
      repositoryOverridePath: nil
    )
    let removedWorktreePath = LockIsolated<String?>(nil)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.defaultWorktreeBaseDirectoryPath = "/tmp/worktrees-changed"
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, _ in
        let workingDirectory = await MainActor.run { worktree.workingDirectory }
        removedWorktreePath.withValue { $0 = workingDirectory.path(percentEncoded: false) }
        return workingDirectory
      }
      $0.gitClient.pruneWorktrees = { _ in }
    }
    store.exhaustivity = .off

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("boom")
    }

    await store.send(
      .createRandomWorktreeFailed(
        title: "Unable to create worktree",
        message: "boom",
        pendingID: "pending:test",
        previousSelection: nil,
        repositoryID: repository.id,
        name: "new-branch",
        baseDirectory: createTimeBaseDirectory
      )
    ) {
      $0.alert = expectedAlert
    }
    await store.finish()

    #expect(changedBaseDirectory != createTimeBaseDirectory)
    #expect(removedWorktreePath.value != nil)
    #expect(
      removedWorktreePath.value
        == createTimeBaseDirectory
        .appending(path: "new-branch", directoryHint: .isDirectory)
        .path(percentEncoded: false)
    )
    #expect(
      removedWorktreePath.value
        != changedBaseDirectory
        .appending(path: "new-branch", directoryHint: .isDirectory)
        .path(percentEncoded: false)
    )
  }

  @Test func pendingProgressUpdateUpdatesPendingWorktreeState() async {
    let repoRoot = "/tmp/repo"
    let repository = makeRepository(
      id: repoRoot,
      worktrees: [makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)]
    )
    let pendingID = "pending:test"
    var state = makeState(repositories: [repository])
    state.selection = .worktree(pendingID)
    state.pendingWorktrees = [
      PendingWorktree(
        id: pendingID,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(stage: .loadingLocalBranches)
      ),
    ]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    let nextProgress = WorktreeCreationProgress(
      stage: .creatingWorktree,
      worktreeName: "swift-otter",
      baseRef: "origin/main",
      copyIgnored: false,
      copyUntracked: true
    )
    await store.send(
      .pendingWorktreeProgressUpdated(
        id: pendingID,
        progress: nextProgress
      )
    ) {
      $0.pendingWorktrees[0].progress = nextProgress
    }
  }

  @Test func pendingProgressUpdateIsIgnoredAfterCreateFailureRemovesPendingWorktree() async {
    let repoRoot = "/tmp/repo"
    let repository = makeRepository(id: repoRoot, worktrees: [makeWorktree(id: repoRoot, name: "main")])
    let pendingID = "pending:test"
    var state = makeState(repositories: [repository])
    state.selection = .worktree(pendingID)
    state.pendingWorktrees = [
      PendingWorktree(
        id: pendingID,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(
          stage: .checkingRepositoryMode,
          worktreeName: "swift-otter"
        )
      ),
    ]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("boom")
    }

    await store.send(
      .createRandomWorktreeFailed(
        title: "Unable to create worktree",
        message: "boom",
        pendingID: pendingID,
        previousSelection: nil,
        repositoryID: repository.id,
        name: nil,
        baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees")
      )
    ) {
      $0.pendingWorktrees = []
      $0.selection = nil
      $0.alert = expectedAlert
    }

    await store.send(
      .pendingWorktreeProgressUpdated(
        id: pendingID,
        progress: WorktreeCreationProgress(stage: .creatingWorktree)
      )
    )
    #expect(store.state.pendingWorktrees.isEmpty)
  }

  @Test func requestDeleteWorktreeShowsConfirmation() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "owl")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("🚨 Delete worktree?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmDeleteWorktree(worktree.id, repository.id)) {
        TextState("Delete (⌘↩)")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("Delete \(worktree.name)? This deletes the worktree directory and its local branch.")
    }

    await store.send(.requestDeleteWorktree(worktree.id, repository.id)) {
      $0.alert = expectedAlert
    }
  }

  @Test func requestDeleteMainWorktreeShowsNotAllowedAlert() async {
    let mainWorktree = makeWorktree(id: "/tmp/repo", name: "main")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [mainWorktree])

    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Delete not allowed")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Deleting the main worktree is not allowed.")
    }

    await store.send(.requestDeleteWorktree(mainWorktree.id, repository.id)) {
      $0.alert = expectedAlert
    }
  }
  @Test func requestDeleteWorktreesShowsBatchConfirmation() async {
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "owl", repoRoot: "/tmp/repo")
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "hawk", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree1, worktree2])
    let targets = [
      RepositoriesFeature.DeleteWorktreeTarget(worktreeID: worktree1.id, repositoryID: repository.id),
      RepositoriesFeature.DeleteWorktreeTarget(worktreeID: worktree2.id, repositoryID: repository.id),
    ]
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("🚨 Delete 2 worktrees?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmDeleteWorktrees(targets)) {
        TextState("Delete 2 (⌘↩)")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("Delete 2 worktrees? This deletes the worktree directories and their local branches.")
    }

    await store.send(.requestDeleteWorktrees(targets)) {
      $0.alert = expectedAlert
    }
  }

  @Test func requestArchiveWorktreeShowsConfirmation() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "owl")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Archive worktree?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmArchiveWorktree(worktree.id, repository.id)) {
        TextState("Archive (⌘↩)")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("Archive \(worktree.name)?")
    }

    await store.send(.requestArchiveWorktree(worktree.id, repository.id)) {
      $0.alert = expectedAlert
    }
  }

  @Test func requestArchiveWorktreesShowsBatchConfirmation() async {
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "owl", repoRoot: "/tmp/repo")
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "hawk", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree1, worktree2])
    let targets = [
      RepositoriesFeature.ArchiveWorktreeTarget(worktreeID: worktree1.id, repositoryID: repository.id),
      RepositoriesFeature.ArchiveWorktreeTarget(worktreeID: worktree2.id, repositoryID: repository.id),
    ]
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Archive 2 worktrees?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmArchiveWorktrees(targets)) {
        TextState("Archive 2 (⌘↩)")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("Archive 2 worktrees?")
    }

    await store.send(.requestArchiveWorktrees(targets)) {
      $0.alert = expectedAlert
    }
  }

  @Test func requestArchiveWorktreeMergedArchivesImmediately() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(featureWorktree.id)
    state.pinnedWorktreeIDs = [featureWorktree.id]
    state.worktreeOrderByRepository[repoRoot] = [featureWorktree.id]
    state.worktreeInfoByID = [
      featureWorktree.id: WorktreeInfoEntry(
        addedLines: nil,
        removedLines: nil,
        pullRequest: makePullRequest(state: "MERGED")
      ),
    ]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.requestArchiveWorktree(featureWorktree.id, repository.id))
    await store.receive(\.archiveWorktreeConfirmed)
    await store.receive(\.archiveWorktreeApply) {
      $0.archivedWorktreeIDs = [featureWorktree.id]
      $0.pinnedWorktreeIDs = []
      $0.worktreeOrderByRepository = [:]
      $0.selection = .worktree(mainWorktree.id)
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test(.dependencies) func archiveWorktreeConfirmedRunsArchiveScriptAndShowsProgress() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(mainWorktree.id)
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.archiveScript = "echo syncing\necho done"
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.shellClient.runLoginStreamImpl = { _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.line(ShellStreamLine(source: .stdout, text: "syncing")))
          continuation.yield(.line(ShellStreamLine(source: .stdout, text: "done")))
          continuation.yield(.finished(ShellOutput(stdout: "syncing\ndone", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    }

    await store.send(.archiveWorktreeConfirmed(featureWorktree.id, repository.id)) {
      $0.archivingWorktreeIDs = [featureWorktree.id]
      $0.archiveScriptProgressByWorktreeID[featureWorktree.id] = ArchiveScriptProgress(
        titleText: "Running archive script",
        detailText: "Preparing archive script",
        commandText: "bash -lc 'echo syncing\\necho done'"
      )
    }
    await store.receive(\.archiveScriptProgressUpdated) {
      $0.archiveScriptProgressByWorktreeID[featureWorktree.id] = ArchiveScriptProgress(
        titleText: "Running archive script",
        detailText: "syncing",
        commandText: "bash -lc 'echo syncing\\necho done'",
        outputLines: ["syncing"]
      )
    }
    await store.receive(\.archiveScriptProgressUpdated) {
      $0.archiveScriptProgressByWorktreeID[featureWorktree.id] = ArchiveScriptProgress(
        titleText: "Running archive script",
        detailText: "done",
        commandText: "bash -lc 'echo syncing\\necho done'",
        outputLines: ["syncing", "done"]
      )
    }
    await store.receive(\.archiveScriptSucceeded) {
      $0.archivingWorktreeIDs = []
      $0.archiveScriptProgressByWorktreeID = [:]
    }
    await store.receive(\.archiveWorktreeApply) {
      $0.archivedWorktreeIDs = [featureWorktree.id]
    }
    await store.receive(\.delegate.repositoriesChanged)
  }

  @Test(.dependencies) func archiveWorktreeConfirmedScriptFailureBlocksArchive() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.archiveScript = "exit 7"
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.shellClient.runLoginStreamImpl = { _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.finish(
            throwing: ShellClientError(
              command: "bash -lc exit 7",
              stdout: "",
              stderr: "fail",
              exitCode: 7
            )
          )
        }
      }
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Archive script failed")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Command failed: bash -lc exit 7\nstderr:\nfail")
    }

    await store.send(.archiveWorktreeConfirmed(featureWorktree.id, repository.id)) {
      $0.archivingWorktreeIDs = [featureWorktree.id]
      $0.archiveScriptProgressByWorktreeID[featureWorktree.id] = ArchiveScriptProgress(
        titleText: "Running archive script",
        detailText: "Preparing archive script",
        commandText: "bash -lc 'exit 7'"
      )
    }
    await store.receive(\.archiveScriptFailed) {
      $0.archivingWorktreeIDs = []
      $0.archiveScriptProgressByWorktreeID = [:]
      $0.alert = expectedAlert
    }
    #expect(store.state.archivedWorktreeIDs.isEmpty)
  }

  @Test func archiveScriptSucceededIgnoredWhenNotArchiving() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.archiveScriptSucceeded(worktreeID: featureWorktree.id, repositoryID: repository.id))
    #expect(store.state.archivedWorktreeIDs.isEmpty)
  }

  @Test func archiveScriptFailedIgnoredWhenNotArchiving() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.archiveScriptFailed(worktreeID: featureWorktree.id, message: "late failure"))
    #expect(store.state.alert == nil)
    #expect(store.state.archivedWorktreeIDs.isEmpty)
  }

  @Test func repositoriesLoadedKeepsArchiveInFlightUntilSuccessCompletion() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let reloadedRepository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.archivingWorktreeIDs = [featureWorktree.id]
    state.archiveScriptProgressByWorktreeID[featureWorktree.id] = ArchiveScriptProgress(
      titleText: "Running archive script",
      detailText: "still running"
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .repositoriesLoaded(
        [reloadedRepository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    )
    #expect(store.state.archivingWorktreeIDs.contains(featureWorktree.id))
    #expect(store.state.archiveScriptProgressByWorktreeID[featureWorktree.id] != nil)

    await store.send(.archiveScriptSucceeded(worktreeID: featureWorktree.id, repositoryID: repository.id))
    #expect(store.state.archivingWorktreeIDs.isEmpty)
    #expect(store.state.archiveScriptProgressByWorktreeID.isEmpty)
  }

  @Test func repositoriesLoadedKeepsArchiveInFlightUntilFailureCompletion() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let reloadedRepository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.archivingWorktreeIDs = [featureWorktree.id]
    state.archiveScriptProgressByWorktreeID[featureWorktree.id] = ArchiveScriptProgress(
      titleText: "Running archive script",
      detailText: "still running"
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .repositoriesLoaded(
        [reloadedRepository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    )
    #expect(store.state.archivingWorktreeIDs.contains(featureWorktree.id))
    #expect(store.state.archiveScriptProgressByWorktreeID[featureWorktree.id] != nil)

    await store.send(.archiveScriptFailed(worktreeID: featureWorktree.id, message: "script failed"))
    #expect(store.state.archivingWorktreeIDs.isEmpty)
    #expect(store.state.archiveScriptProgressByWorktreeID.isEmpty)
    #expect(store.state.alert != nil)
  }

  @Test func requestRenameBranchWithEmptyNameShowsAlert() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "eagle")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Branch name required")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Enter a branch name to rename.")
    }

    await store.send(.requestRenameBranch(worktree.id, " ")) {
      $0.alert = expectedAlert
    }
  }

  @Test func requestRenameBranchWithWhitespaceShowsAlert() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "eagle")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Branch name invalid")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Branch names can't contain spaces.")
    }

    await store.send(.requestRenameBranch(worktree.id, "feature branch")) {
      $0.alert = expectedAlert
    }
  }

  @Test func worktreeNotificationReceivedDoesNotShowStatusToast() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeOrderByRepository[repoRoot] = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeNotificationReceived(featureWorktree.id))
    #expect(store.state.statusToast == nil)
  }

  @Test func worktreeNotificationReceivedReordersUnpinnedWorktrees() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureA = makeWorktree(id: "/tmp/repo/a", name: "a", repoRoot: repoRoot)
    let featureB = makeWorktree(id: "/tmp/repo/b", name: "b", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureA, featureB])
    var state = makeState(repositories: [repository])
    state.worktreeOrderByRepository[repoRoot] = [featureA.id, featureB.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeNotificationReceived(featureB.id)) {
      $0.worktreeOrderByRepository[repoRoot] = [featureB.id, featureA.id]
    }
    #expect(store.state.statusToast == nil)
  }

  @Test func worktreeNotificationReceivedDoesNotReorderWhenMoveToTopDisabled() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureA = makeWorktree(id: "/tmp/repo/a", name: "a", repoRoot: repoRoot)
    let featureB = makeWorktree(id: "/tmp/repo/b", name: "b", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureA, featureB])
    var state = makeState(repositories: [repository])
    state.worktreeOrderByRepository[repoRoot] = [featureA.id, featureB.id]
    state.moveNotifiedWorktreeToTop = false
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeNotificationReceived(featureB.id))
    #expect(store.state.worktreeOrderByRepository[repoRoot] == [featureA.id, featureB.id])
    #expect(store.state.statusToast == nil)
  }

  @Test func setMoveNotifiedWorktreeToTopUpdatesState() async {
    var state = makeState(repositories: [])
    state.moveNotifiedWorktreeToTop = true
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.setMoveNotifiedWorktreeToTop(false)) {
      $0.moveNotifiedWorktreeToTop = false
    }
  }

  @Test func worktreeBranchNameLoadedPreservesCreatedAt() async {
    let createdAt = Date(timeIntervalSince1970: 1_737_303_600)
    let worktree = makeWorktree(id: "/tmp/wt", name: "eagle", createdAt: createdAt)
    let renamedWorktree = makeWorktree(id: "/tmp/wt", name: "falcon", createdAt: createdAt)
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.worktreeBranchNameLoaded(worktreeID: worktree.id, name: "falcon")) {
      var repository = $0.repositories[id: repository.id]!
      var worktrees = repository.worktrees
      worktrees[id: worktree.id] = renamedWorktree
      repository = Repository(
        id: repository.id,
        rootURL: repository.rootURL,
        name: repository.name,
        worktrees: worktrees
      )
      $0.repositories[id: repository.id] = repository
    }
    #expect(store.state.repositories[id: repository.id]?.worktrees[id: worktree.id]?.name == "falcon")
    #expect(store.state.repositories[id: repository.id]?.worktrees[id: worktree.id]?.createdAt == createdAt)
  }

  @Test func orderedWorktreeRowsAreGlobal() {
    let repoA = makeRepository(
      id: "/tmp/repo-a",
      worktrees: [
        makeWorktree(id: "/tmp/repo-a/wt1", name: "wt1", repoRoot: "/tmp/repo-a"),
        makeWorktree(id: "/tmp/repo-a/wt2", name: "wt2", repoRoot: "/tmp/repo-a"),
      ]
    )
    let repoB = makeRepository(
      id: "/tmp/repo-b",
      worktrees: [
        makeWorktree(id: "/tmp/repo-b/wt3", name: "wt3", repoRoot: "/tmp/repo-b")
      ]
    )
    let state = makeState(repositories: [repoA, repoB])

    expectNoDifference(
      state.orderedWorktreeRows().map(\.id),
      [
        "/tmp/repo-a/wt1",
        "/tmp/repo-a/wt2",
        "/tmp/repo-b/wt3",
      ]
    )
  }

  @Test func orderedWorktreeRowsRespectRepositoryOrderIDs() {
    let repoA = makeRepository(
      id: "/tmp/repo-a",
      worktrees: [
        makeWorktree(id: "/tmp/repo-a/wt1", name: "wt1", repoRoot: "/tmp/repo-a")
      ]
    )
    let repoB = makeRepository(
      id: "/tmp/repo-b",
      worktrees: [
        makeWorktree(id: "/tmp/repo-b/wt2", name: "wt2", repoRoot: "/tmp/repo-b")
      ]
    )
    var state = makeState(repositories: [repoA, repoB])
    state.repositoryOrderIDs = [repoB.id, repoA.id]

    expectNoDifference(
      state.orderedWorktreeRows().map(\.id),
      [
        "/tmp/repo-b/wt2",
        "/tmp/repo-a/wt1",
      ]
    )
  }

  @Test func orderedWorktreeRowsCanFilterCollapsedRepositoriesForHotkeys() {
    let repoA = makeRepository(
      id: "/tmp/repo-a",
      worktrees: [
        makeWorktree(id: "/tmp/repo-a/wt1", name: "wt1", repoRoot: "/tmp/repo-a")
      ]
    )
    let repoB = makeRepository(
      id: "/tmp/repo-b",
      worktrees: [
        makeWorktree(id: "/tmp/repo-b/wt2", name: "wt2", repoRoot: "/tmp/repo-b")
      ]
    )
    var state = makeState(repositories: [repoA, repoB])
    state.repositoryOrderIDs = [repoA.id, repoB.id]

    expectNoDifference(
      state.orderedWorktreeRows(includingRepositoryIDs: [repoB.id]).map(\.id),
      [
        "/tmp/repo-b/wt2"
      ]
    )
  }

  @Test func orderedRepositoryRootsAppendMissing() {
    let repoA = makeRepository(id: "/tmp/repo-a", worktrees: [])
    let repoB = makeRepository(id: "/tmp/repo-b", worktrees: [])
    var state = makeState(repositories: [repoA, repoB])
    state.repositoryOrderIDs = [repoB.id]

    expectNoDifference(
      state.orderedRepositoryRoots().map { $0.path(percentEncoded: false) },
      [
        repoB.id,
        repoA.id,
      ]
    )
  }

  @Test func orderedUnpinnedWorktreesPutMissingFirst() {
    let repoRoot = "/tmp/repo"
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: repoRoot)
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: repoRoot)
    let worktree3 = makeWorktree(id: "/tmp/repo/wt3", name: "wt3", repoRoot: repoRoot)
    let repository = makeRepository(
      id: repoRoot,
      worktrees: [worktree1, worktree2, worktree3]
    )
    var state = makeState(repositories: [repository])
    state.worktreeOrderByRepository[repoRoot] = [worktree2.id]

    expectNoDifference(
      state.orderedUnpinnedWorktreeIDs(in: repository),
      [
        worktree1.id,
        worktree3.id,
        worktree2.id,
      ]
    )
  }

  @Test func unpinnedWorktreeMoveUpdatesOrder() async {
    let repoRoot = "/tmp/repo"
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: repoRoot)
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: repoRoot)
    let worktree3 = makeWorktree(id: "/tmp/repo/wt3", name: "wt3", repoRoot: repoRoot)
    let repository = makeRepository(
      id: repoRoot,
      worktrees: [worktree1, worktree2, worktree3]
    )
    var state = makeState(repositories: [repository])
    state.worktreeOrderByRepository[repoRoot] = [worktree1.id, worktree2.id, worktree3.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.unpinnedWorktreesMoved(repositoryID: repoRoot, IndexSet(integer: 0), 3)) {
      $0.worktreeOrderByRepository[repoRoot] = [worktree2.id, worktree3.id, worktree1.id]
    }
  }

  @Test func pinnedWorktreeMoveUpdatesSubsetOrder() async {
    let repoA = "/tmp/repo-a"
    let repoB = "/tmp/repo-b"
    let worktreeA1 = makeWorktree(id: "/tmp/repo-a/wt1", name: "wt1", repoRoot: repoA)
    let worktreeA2 = makeWorktree(id: "/tmp/repo-a/wt2", name: "wt2", repoRoot: repoA)
    let worktreeB1 = makeWorktree(id: "/tmp/repo-b/wt1", name: "wt1", repoRoot: repoB)
    let repositoryA = makeRepository(id: repoA, worktrees: [worktreeA1, worktreeA2])
    let repositoryB = makeRepository(id: repoB, worktrees: [worktreeB1])
    var state = makeState(repositories: [repositoryA, repositoryB])
    state.pinnedWorktreeIDs = [worktreeA1.id, worktreeB1.id, worktreeA2.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.pinnedWorktreesMoved(repositoryID: repoA, IndexSet(integer: 1), 0)) {
      $0.pinnedWorktreeIDs = [worktreeA2.id, worktreeB1.id, worktreeA1.id]
    }
  }

  @Test func loadRepositoriesFailureKeepsPreviousState() async {
    let repository = makeRepository(id: "/tmp/repo", worktrees: [])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [],
        failures: [RepositoriesFeature.LoadFailure(rootID: repository.id, message: "boom")],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.loadFailuresByID = [repository.id: "boom"]
      $0.repositories = []
      $0.isInitialLoadComplete = true
    }

    await store.receive(\.delegate.repositoriesChanged)
  }

  @Test func worktreeOrderPreservedWhenRepositoryLoadFails() async {
    let repoRoot = "/tmp/repo"
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: repoRoot)
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree1, worktree2])
    var initialState = makeState(repositories: [repository])
    initialState.worktreeOrderByRepository = [
      repoRoot: [worktree1.id, worktree2.id]
    ]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [],
        failures: [RepositoriesFeature.LoadFailure(rootID: repository.id, message: "boom")],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.loadFailuresByID = [repository.id: "boom"]
      $0.repositories = []
      $0.isInitialLoadComplete = true
    }

    await store.receive(\.delegate.repositoriesChanged)
    expectNoDifference(
      store.state.worktreeOrderByRepository,
      [repoRoot: [worktree1.id, worktree2.id]]
    )
  }

  @Test func archivedWorktreeIDsPreservedWhenRepositoryLoadFails() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.archivedWorktreeIDs = [worktree.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [],
        failures: [RepositoriesFeature.LoadFailure(rootID: repository.id, message: "boom")],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.loadFailuresByID = [repository.id: "boom"]
      $0.repositories = []
      $0.isInitialLoadComplete = true
    }

    await store.receive(\.delegate.repositoriesChanged)
    #expect(store.state.archivedWorktreeIDs == [worktree.id])
  }

  @Test func repositoriesLoadedSkipsSelectionChangeWhenOnlyDisplayDataChanges() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let updatedWorktree = makeWorktree(id: "/tmp/repo/main", name: "main-updated", repoRoot: repoRoot)
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [updatedWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [updatedRepository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.repositories = [updatedRepository]
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()
  }

  @Test func repositoriesLoadedUpdatesSelectedWorktreeDelegateOnSelectionChange() async {
    let repoRoot = "/tmp/repo"
    let selectedWorktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: repoRoot)
    let remainingWorktree = makeWorktree(id: "/tmp/repo/next", name: "next", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [selectedWorktree, remainingWorktree])
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [remainingWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(selectedWorktree.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [updatedRepository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.repositories = [updatedRepository]
      $0.selection = nil
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func worktreeDeletedPrunesStateAndSendsDelegates() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: repoRoot)
    let removedWorktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, removedWorktree])
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(mainWorktree.id)
    initialState.deletingWorktreeIDs = [removedWorktree.id]
    initialState.pendingSetupScriptWorktreeIDs = [removedWorktree.id]
    initialState.pendingTerminalFocusWorktreeIDs = [removedWorktree.id]
    initialState.pendingWorktrees = [
      PendingWorktree(
        id: removedWorktree.id,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(stage: .choosingWorktreeName)
      ),
    ]
    initialState.pinnedWorktreeIDs = [removedWorktree.id]
    initialState.worktreeInfoByID = [
      removedWorktree.id: WorktreeInfoEntry(addedLines: 1, removedLines: 2, pullRequest: nil)
    ]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }

    await store.send(
      .worktreeDeleted(
        removedWorktree.id,
        repositoryID: repository.id,
        selectionWasRemoved: false,
        nextSelection: nil
      )
    ) {
      $0.deletingWorktreeIDs = []
      $0.pendingSetupScriptWorktreeIDs = []
      $0.pendingTerminalFocusWorktreeIDs = []
      $0.pendingWorktrees = []
      $0.pinnedWorktreeIDs = []
      $0.worktreeInfoByID = [:]
      $0.repositories = [updatedRepository]
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.reloadRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
    }
  }

  @Test func worktreeDeletedResetsSelectionWhenDriftedToDeletingWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: repoRoot)
    let removedWorktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, removedWorktree])
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(removedWorktree.id)
    initialState.deletingWorktreeIDs = [removedWorktree.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }

    await store.send(
      .worktreeDeleted(
        removedWorktree.id,
        repositoryID: repository.id,
        selectionWasRemoved: false,
        nextSelection: nil
      )
    ) {
      $0.deletingWorktreeIDs = []
      $0.repositories = [updatedRepository]
      $0.selection = .worktree(mainWorktree.id)
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.reloadRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
    }
  }

  @Test func createRandomWorktreeSucceededSendsRepositoriesChanged() async {
    let repoRoot = "/tmp/repo"
    let existingWorktree = makeWorktree(id: "/tmp/repo/wt-main", name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [existingWorktree])
    let newWorktree = makeWorktree(id: "/tmp/repo/wt-new", name: "new", repoRoot: repoRoot)
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [newWorktree, existingWorktree])
    let pendingID = "pending:\(UUID().uuidString)"
    var initialState = makeState(repositories: [repository])
    initialState.pendingWorktrees = [
      PendingWorktree(
        id: pendingID,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(stage: .loadingLocalBranches)
      ),
    ]
    initialState.selection = .worktree(pendingID)
    initialState.sidebarSelectedWorktreeIDs = [existingWorktree.id, pendingID]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.worktrees = { _ in [newWorktree, existingWorktree] }
    }

    await store.send(
      .createRandomWorktreeSucceeded(
        newWorktree,
        repositoryID: repository.id,
        pendingID: pendingID
      )
    ) {
      $0.pendingSetupScriptWorktreeIDs.insert(newWorktree.id)
      $0.pendingTerminalFocusWorktreeIDs.insert(newWorktree.id)
      $0.pendingWorktrees = []
      $0.selection = .worktree(newWorktree.id)
      $0.sidebarSelectedWorktreeIDs = [newWorktree.id]
      $0.repositories = [updatedRepository]
    }

    await store.receive(\.reloadRepositories)
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.delegate.worktreeCreated)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
    }
  }

  @Test func repositoryPullRequestsLoadedAutoArchivesWhenEnabled() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.automaticallyArchiveMergedWorktrees = true
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: featureWorktree.name)

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [featureWorktree.id: mergedPullRequest]
      )
    ) {
      $0.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
        addedLines: nil,
        removedLines: nil,
        pullRequest: mergedPullRequest
      )
    }
    await store.receive(\.archiveWorktreeConfirmed)
    await store.receive(\.archiveWorktreeApply) {
      $0.archivedWorktreeIDs = [featureWorktree.id]
    }
    await store.receive(\.delegate.repositoriesChanged)
  }

  @Test func repositoryPullRequestsLoadedSkipsAutoArchiveForMainWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.automaticallyArchiveMergedWorktrees = true
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: mainWorktree.name)

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [mainWorktree.id: mergedPullRequest]
      )
    ) {
      $0.worktreeInfoByID[mainWorktree.id] = WorktreeInfoEntry(
        addedLines: nil,
        removedLines: nil,
        pullRequest: mergedPullRequest
      )
    }
    await store.finish()
  }

  @Test func pullRequestActionMergeRefreshesImmediatelyWithoutSyntheticMergedState() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let openPullRequest = makePullRequest(state: "OPEN", headRefName: featureWorktree.name, number: 12)
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .disabled
    state.automaticallyArchiveMergedWorktrees = true
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: openPullRequest
    )
    let mergedNumbers = LockIsolated<[Int]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { true }
      $0.githubCLI.mergePullRequest = { _, number, _ in
        mergedNumbers.withValue { $0.append(number) }
      }
    }
    store.exhaustivity = .off

    await store.send(.pullRequestAction(featureWorktree.id, .merge))
    await store.receive(\.showToast) {
      $0.statusToast = .inProgress("Merging pull request…")
    }
    await store.receive(\.showToast) {
      $0.statusToast = .success("Pull request merged")
    }
    await store.receive(\.worktreeInfoEvent)
    #expect(store.state.worktreeInfoByID[featureWorktree.id]?.pullRequest?.state == "OPEN")
    #expect(store.state.archivedWorktreeIDs.isEmpty)
    #expect(mergedNumbers.value == [12])
    await store.finish()
  }

  @Test func pullRequestActionCloseRefreshesImmediately() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let openPullRequest = makePullRequest(state: "OPEN", headRefName: featureWorktree.name, number: 12)
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .disabled
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: openPullRequest
    )
    let closedNumbers = LockIsolated<[Int]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { true }
      $0.githubCLI.closePullRequest = { _, number in
        closedNumbers.withValue { $0.append(number) }
      }
    }
    store.exhaustivity = .off

    await store.send(.pullRequestAction(featureWorktree.id, .close))
    await store.receive(\.showToast) {
      $0.statusToast = .inProgress("Closing pull request…")
    }
    await store.receive(\.showToast) {
      $0.statusToast = .success("Pull request closed")
    }
    await store.receive(\.worktreeInfoEvent)
    #expect(closedNumbers.value == [12])
    await store.finish()
  }

  @Test func worktreeInfoEventRepositoryPullRequestRefreshMarksInFlightThenCompletes() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .available
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.remoteInfo = { _ in nil }
      $0.githubCLI.batchPullRequests = { _, _, _, _ in
        Issue.record("batchPullRequests should not run when remoteInfo is unavailable")
        return [:]
      }
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: URL(fileURLWithPath: repoRoot),
          worktreeIDs: [mainWorktree.id, featureWorktree.id]
        )
      )
    ) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [repository.id]
    }
    await store.receive(\.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func worktreeInfoEventRepositoryPullRequestRefreshQueuesWhileAvailabilityUnknown() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { false }
      $0.gitClient.remoteInfo = { _ in
        Issue.record("remoteInfo should not be requested when GitHub integration is unavailable")
        return nil
      }
      $0.githubCLI.batchPullRequests = { _, _, _, _ in
        Issue.record("batchPullRequests should not run when GitHub integration is unavailable")
        return [:]
      }
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: URL(fileURLWithPath: repoRoot),
          worktreeIDs: [mainWorktree.id, featureWorktree.id]
        )
      )
    ) {
      $0.pendingPullRequestRefreshByRepositoryID[repository.id] = RepositoriesFeature.PendingPullRequestRefresh(
        repositoryRootURL: URL(fileURLWithPath: repoRoot),
        worktreeIDs: [mainWorktree.id, featureWorktree.id]
      )
    }
    await store.receive(\.refreshGithubIntegrationAvailability) {
      $0.githubIntegrationAvailability = .checking
    }
    await store.receive(\.githubIntegrationAvailabilityUpdated) {
      $0.githubIntegrationAvailability = .unavailable
      $0.queuedPullRequestRefreshByRepositoryID = [:]
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.send(.setGithubIntegrationEnabled(false)) {
      $0.githubIntegrationAvailability = .disabled
      $0.pendingPullRequestRefreshByRepositoryID = [:]
      $0.queuedPullRequestRefreshByRepositoryID = [:]
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func worktreeInfoEventRepositoryPullRequestRefreshQueuesWhileAvailabilityUnavailable() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .unavailable
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: URL(fileURLWithPath: repoRoot),
          worktreeIDs: [mainWorktree.id, featureWorktree.id]
        )
      )
    ) {
      $0.pendingPullRequestRefreshByRepositoryID[repository.id] = RepositoriesFeature.PendingPullRequestRefresh(
        repositoryRootURL: URL(fileURLWithPath: repoRoot),
        worktreeIDs: [mainWorktree.id, featureWorktree.id]
      )
    }
    await store.finish()
  }

  @Test func githubIntegrationAvailabilityRecoveryReplaysPendingRefreshes() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .unavailable
    initialState.pendingPullRequestRefreshByRepositoryID[repository.id] = RepositoriesFeature.PendingPullRequestRefresh(
      repositoryRootURL: URL(fileURLWithPath: repoRoot),
      worktreeIDs: [mainWorktree.id, featureWorktree.id]
    )
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.remoteInfo = { _ in nil }
      $0.githubCLI.batchPullRequests = { _, _, _, _ in
        Issue.record("batchPullRequests should not run when remoteInfo is unavailable")
        return [:]
      }
    }

    await store.send(.githubIntegrationAvailabilityUpdated(true)) {
      $0.githubIntegrationAvailability = .available
      $0.pendingPullRequestRefreshByRepositoryID = [:]
    }
    await store.receive(\.worktreeInfoEvent) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [repository.id]
    }
    await store.receive(\.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func githubIntegrationAvailabilityUnavailablePromotesQueuedRefreshesToPending() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .available
    initialState.inFlightPullRequestRefreshRepositoryIDs = [repository.id]
    initialState.queuedPullRequestRefreshByRepositoryID[repository.id] = RepositoriesFeature.PendingPullRequestRefresh(
      repositoryRootURL: URL(fileURLWithPath: repoRoot),
      worktreeIDs: [mainWorktree.id, featureWorktree.id]
    )
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.githubIntegrationAvailabilityUpdated(false)) {
      $0.githubIntegrationAvailability = .unavailable
      $0.pendingPullRequestRefreshByRepositoryID[repository.id] = RepositoriesFeature.PendingPullRequestRefresh(
        repositoryRootURL: URL(fileURLWithPath: repoRoot),
        worktreeIDs: [mainWorktree.id, featureWorktree.id]
      )
      $0.queuedPullRequestRefreshByRepositoryID = [:]
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.send(.setGithubIntegrationEnabled(false)) {
      $0.githubIntegrationAvailability = .disabled
      $0.pendingPullRequestRefreshByRepositoryID = [:]
      $0.queuedPullRequestRefreshByRepositoryID = [:]
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func githubIntegrationAvailabilityUpdatedWhileDisabledIsIgnored() async {
    var state = makeState(repositories: [])
    state.githubIntegrationAvailability = .disabled
    state.pendingPullRequestRefreshByRepositoryID["repo"] = RepositoriesFeature.PendingPullRequestRefresh(
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
      worktreeIDs: []
    )
    let expectedState = state
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.githubIntegrationAvailabilityUpdated(false))
    await store.send(.githubIntegrationAvailabilityUpdated(true))
    #expect(store.state == expectedState)
    await store.finish()
  }

  @Test func repositoryPullRequestRefreshCompletedReplaysQueuedRefresh() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .available
    state.inFlightPullRequestRefreshRepositoryIDs = [repository.id]
    state.queuedPullRequestRefreshByRepositoryID[repository.id] =
      RepositoriesFeature
      .PendingPullRequestRefresh(
        repositoryRootURL: URL(fileURLWithPath: repoRoot),
        worktreeIDs: [mainWorktree.id, featureWorktree.id]
      )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.remoteInfo = { _ in nil }
      $0.githubCLI.batchPullRequests = { _, _, _, _ in
        Issue.record("batchPullRequests should not run when remoteInfo is unavailable")
        return [:]
      }
    }

    await store.send(
      .repositoryPullRequestRefreshCompleted(repository.id)
    ) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
      $0.queuedPullRequestRefreshByRepositoryID = [:]
    }
    await store.receive(\.worktreeInfoEvent) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [repository.id]
    }
    await store.receive(\.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func repositoryPullRequestsLoadedSkipsNoopPayload() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let pullRequest = makePullRequest(state: "OPEN", headRefName: featureWorktree.name)
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: pullRequest
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [featureWorktree.id: pullRequest]
      )
    )
    await store.finish()
  }

  @Test func repositoryPullRequestsLoadedClearsStalePullRequestWhenNil() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: makePullRequest(state: "OPEN", headRefName: featureWorktree.name)
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let pullRequestsByWorktreeID: [Worktree.ID: GithubPullRequest?] = [featureWorktree.id: nil]

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: pullRequestsByWorktreeID
      )
    ) {
      $0.worktreeInfoByID.removeValue(forKey: featureWorktree.id)
    }
  }

  @Test func unarchiveWorktreeNoopsWhenNotArchived() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "owl")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.unarchiveWorktree(worktree.id))
    expectNoDifference(store.state.archivedWorktreeIDs, [])
  }

  // MARK: - Select Next/Previous Worktree

  @Test func selectNextWorktreeWrapsForward() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt2.id)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectPreviousWorktreeWrapsBackward() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectPreviousWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectNextWorktreeWithNoSelectionSelectsFirst() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectNextWorktreeCollapsesSidebarSelectionToSingleWorktree() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let wt3 = makeWorktree(id: "/tmp/wt3", name: "gamma")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2, wt3])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    state.sidebarSelectedWorktreeIDs = [wt1.id, wt3.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectPreviousWorktreeWithNoSelectionSelectsLast() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.selectPreviousWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectNextWorktreeWithEmptyRowsIsNoOp() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
  }

  @Test func selectNextWorktreeSingleWorktreeReturnsSame() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "solo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(worktree.id)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(worktree.id)
      $0.sidebarSelectedWorktreeIDs = [worktree.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectNextWorktreeSkipsCollapsedRepository() async {
    let wt1 = makeWorktree(id: "/tmp/repo1/wt1", name: "alpha", repoRoot: "/tmp/repo1")
    let wt2 = makeWorktree(id: "/tmp/repo2/wt2", name: "beta", repoRoot: "/tmp/repo2")
    let wt3 = makeWorktree(id: "/tmp/repo3/wt3", name: "gamma", repoRoot: "/tmp/repo3")
    let repo1 = makeRepository(id: "/tmp/repo1", worktrees: [wt1])
    let repo2 = makeRepository(id: "/tmp/repo2", worktrees: [wt2])
    let repo3 = makeRepository(id: "/tmp/repo3", worktrees: [wt3])
    var state = makeState(repositories: [repo1, repo2, repo3])
    state.selection = .worktree(wt1.id)
    state.$collapsedRepositoryIDs.withLock { $0 = [repo2.id] }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt3.id)
      $0.sidebarSelectedWorktreeIDs = [wt3.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectPreviousWorktreeSkipsCollapsedRepository() async {
    let wt1 = makeWorktree(id: "/tmp/repo1/wt1", name: "alpha", repoRoot: "/tmp/repo1")
    let wt2 = makeWorktree(id: "/tmp/repo2/wt2", name: "beta", repoRoot: "/tmp/repo2")
    let wt3 = makeWorktree(id: "/tmp/repo3/wt3", name: "gamma", repoRoot: "/tmp/repo3")
    let repo1 = makeRepository(id: "/tmp/repo1", worktrees: [wt1])
    let repo2 = makeRepository(id: "/tmp/repo2", worktrees: [wt2])
    let repo3 = makeRepository(id: "/tmp/repo3", worktrees: [wt3])
    var state = makeState(repositories: [repo1, repo2, repo3])
    state.selection = .worktree(wt3.id)
    state.$collapsedRepositoryIDs.withLock { $0 = [repo2.id] }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectPreviousWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectNextWorktreeAllCollapsedIsNoOp() async {
    let wt1 = makeWorktree(id: "/tmp/repo1/wt1", name: "alpha", repoRoot: "/tmp/repo1")
    let repo1 = makeRepository(id: "/tmp/repo1", worktrees: [wt1])
    var state = makeState(repositories: [repo1])
    state.selection = .worktree(wt1.id)
    state.$collapsedRepositoryIDs.withLock { $0 = [repo1.id] }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
  }

  @Test func selectPreviousWorktreeAllCollapsedIsNoOp() async {
    let wt1 = makeWorktree(id: "/tmp/repo1/wt1", name: "alpha", repoRoot: "/tmp/repo1")
    let repo1 = makeRepository(id: "/tmp/repo1", worktrees: [wt1])
    var state = makeState(repositories: [repo1])
    state.selection = .worktree(wt1.id)
    state.$collapsedRepositoryIDs.withLock { $0 = [repo1.id] }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectPreviousWorktree)
  }

  @Test func selectNextWorktreeWrapsAroundSkippingCollapsedRepo() async {
    let wt1 = makeWorktree(id: "/tmp/repo1/wt1", name: "alpha", repoRoot: "/tmp/repo1")
    let wt2 = makeWorktree(id: "/tmp/repo2/wt2", name: "beta", repoRoot: "/tmp/repo2")
    let wt3 = makeWorktree(id: "/tmp/repo3/wt3", name: "gamma", repoRoot: "/tmp/repo3")
    let repo1 = makeRepository(id: "/tmp/repo1", worktrees: [wt1])
    let repo2 = makeRepository(id: "/tmp/repo2", worktrees: [wt2])
    let repo3 = makeRepository(id: "/tmp/repo3", worktrees: [wt3])
    var state = makeState(repositories: [repo1, repo2, repo3])
    state.selection = .worktree(wt3.id)
    state.$collapsedRepositoryIDs.withLock { $0 = [repo2.id] }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  private func makeWorktree(
    id: String,
    name: String,
    repoRoot: String = "/tmp/repo",
    createdAt: Date? = nil
  ) -> Worktree {
    Worktree(
      id: id,
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: repoRoot),
      createdAt: createdAt
    )
  }

  private func makePullRequest(
    state: String,
    headRefName: String? = nil,
    number: Int = 1
  ) -> GithubPullRequest {
    GithubPullRequest(
      number: number,
      title: "PR",
      state: state,
      additions: 0,
      deletions: 0,
      isDraft: false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      url: "https://example.com/pull/\(number)",
      headRefName: headRefName,
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "khoi",
      statusCheckRollup: nil
    )
  }

  private func makeRepository(
    id: String,
    name: String = "repo",
    worktrees: [Worktree]
  ) -> Repository {
    Repository(
      id: id,
      rootURL: URL(fileURLWithPath: id),
      name: name,
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }

  private func makeState(repositories: [Repository]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: repositories)
    state.repositoryRoots = repositories.map(\.rootURL)
    return state
  }

  @Test func loadPersistedRepositoriesStartsFetchesConcurrentlyAndPreservesRootOrder() async {
    let testID = UUID().uuidString
    let repoRootA = "/tmp/\(testID)-repo-a"
    let repoRootB = "/tmp/\(testID)-repo-b"
    let worktreeA = makeWorktree(id: "\(repoRootA)/main", name: "main", repoRoot: repoRootA)
    let worktreeB = makeWorktree(id: "\(repoRootB)/main", name: "main", repoRoot: repoRootB)
    let repoA = makeRepository(
      id: repoRootA,
      name: URL(fileURLWithPath: repoRootA).lastPathComponent,
      worktrees: [worktreeA]
    )
    let repoB = makeRepository(
      id: repoRootB,
      name: URL(fileURLWithPath: repoRootB).lastPathComponent,
      worktrees: [worktreeB]
    )
    let gate = AsyncGate()
    let startedRoots = LockIsolated<Set<String>>([])

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [repoRootA, repoRootB] }
      $0.gitClient.worktrees = { root in
        let path = root.path(percentEncoded: false)
        startedRoots.withValue { $0.insert(path) }
        if path == repoRootA {
          await gate.wait()
          return [worktreeA]
        }
        if path == repoRootB {
          return [worktreeB]
        }
        Issue.record("Unexpected root: \(path)")
        return []
      }
    }

    await store.send(.loadPersistedRepositories)

    var secondFetchStarted = false
    for _ in 0..<100 {
      if startedRoots.value.contains(repoRootB) {
        secondFetchStarted = true
        break
      }
      await Task.yield()
    }
    #expect(secondFetchStarted)

    await gate.resume()

    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [repoA, repoB]
      $0.repositoryRoots = [repoRootA, repoRootB].map { URL(fileURLWithPath: $0) }
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()
  }

  @Test func loadPersistedRepositoriesRestoresLastFocusedSelectionAfterFullLoad() async {
    let testID = UUID().uuidString
    let repoRootA = "/tmp/\(testID)-repo-a"
    let repoRootB = "/tmp/\(testID)-repo-b"
    let worktreeA = makeWorktree(id: "\(repoRootA)/main", name: "main", repoRoot: repoRootA)
    let worktreeB = makeWorktree(id: "\(repoRootB)/main", name: "main", repoRoot: repoRootB)
    let repoA = makeRepository(
      id: repoRootA,
      name: URL(fileURLWithPath: repoRootA).lastPathComponent,
      worktrees: [worktreeA]
    )
    let repoB = makeRepository(
      id: repoRootB,
      name: URL(fileURLWithPath: repoRootB).lastPathComponent,
      worktrees: [worktreeB]
    )

    var state = RepositoriesFeature.State()
    state.lastFocusedWorktreeID = worktreeB.id
    state.shouldRestoreLastFocusedWorktree = true

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [repoRootA, repoRootB] }
      $0.gitClient.worktrees = { root in
        switch root.path(percentEncoded: false) {
        case repoRootA:
          return [worktreeA]
        case repoRootB:
          return [worktreeB]
        default:
          Issue.record("Unexpected root: \(root.path(percentEncoded: false))")
          return []
        }
      }
    }

    await store.send(.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [repoA, repoB]
      $0.repositoryRoots = [repoRootA, repoRootB].map { URL(fileURLWithPath: $0) }
      $0.selection = .worktree(worktreeB.id)
      $0.shouldRestoreLastFocusedWorktree = false
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  private actor AsyncGate {
    var continuation: CheckedContinuation<Void, Never>?
    var isOpen = false

    func wait() async {
      guard !isOpen else { return }
      await withCheckedContinuation { continuation in
        self.continuation = continuation
      }
    }

    func resume() {
      if let continuation {
        continuation.resume()
        self.continuation = nil
      } else {
        isOpen = true
      }
    }
  }
}
