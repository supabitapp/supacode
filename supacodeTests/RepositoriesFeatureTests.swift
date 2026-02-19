import ComposableArchitecture
import CustomDump
import Foundation
import IdentifiedCollections
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
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func refreshWorktreeDiffLoadsDiffPanel() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "fox")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let patch = """
      diff --git a/file.txt b/file.txt
      index 0000000..1111111 100644
      --- a/file.txt
      +++ b/file.txt
      @@ -0,0 +1 @@
      +hello
      """
    let gate = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
    var state = makeState(repositories: [repository])
    state.selection = .worktree(worktree.id)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.diffPatch = { _, _ in
        await withCheckedContinuation { continuation in
          gate.withValue { $0 = continuation }
        }
        return patch
      }
    }

    await store.send(.refreshWorktreeDiff(worktreeID: worktree.id, debounce: false)) {
      $0.worktreeDiffPanel.worktreeID = worktree.id
      $0.worktreeDiffPanel.isLoading = true
    }
    while gate.withValue({ $0 == nil }) {
      await Task.yield()
    }
    gate.withValue {
      $0?.resume()
      $0 = nil
    }
    await store.receive(\.worktreeDiffLoaded) {
      $0.worktreeDiffPanel.worktreeID = worktree.id
      $0.worktreeDiffPanel.patch = patch
      $0.worktreeDiffPanel.isLoading = false
      $0.worktreeDiffPanel.errorMessage = nil
    }

    #expect(store.state.worktreeDiffPanel.worktreeID == worktree.id)
    #expect(store.state.worktreeDiffPanel.patch == patch)
    #expect(store.state.worktreeDiffPanel.isLoading == false)
    #expect(store.state.worktreeDiffPanel.errorMessage == nil)
  }

  @Test func worktreeDiffLoadedIgnoresNonSelectedWorktree() async {
    let selectedWorktree = makeWorktree(id: "/tmp/wt/selected", name: "selected")
    let otherWorktree = makeWorktree(id: "/tmp/wt/other", name: "other")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [selectedWorktree, otherWorktree])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(selectedWorktree.id)
    state.worktreeDiffPanel = RepositoriesFeature.WorktreeDiffPanelState(
      worktreeID: selectedWorktree.id,
      patch: "selected patch",
      isLoading: false,
      errorMessage: nil,
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeDiffLoaded(worktreeID: otherWorktree.id, patch: "other patch"))
    #expect(store.state.worktreeDiffPanel.worktreeID == selectedWorktree.id)
    #expect(store.state.worktreeDiffPanel.patch == "selected patch")
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

  @Test func createRandomWorktreeInRepositoryStreamsOutputLines() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot
    )
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 2 }
      $0.gitClient.untrackedFileCount = { _ in 1 }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _ in
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
    #expect(store.state.pendingSetupScriptWorktreeIDs.contains(createdWorktree.id))
    #expect(store.state.pendingTerminalFocusWorktreeIDs.contains(createdWorktree.id))
    #expect(store.state.repositories[id: repository.id]?.worktrees[id: createdWorktree.id] != nil)
    #expect(store.state.alert == nil)
  }

  @Test func createRandomWorktreeInRepositoryStreamFailureRemovesPendingWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 2 }
      $0.gitClient.untrackedFileCount = { _ in 1 }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _ in
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
        name: nil
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
    await store.receive(\.archiveWorktreeConfirmed) {
      $0.archivedWorktreeIDs = [featureWorktree.id]
      $0.pinnedWorktreeIDs = []
      $0.worktreeOrderByRepository = [:]
      $0.selection = .worktree(mainWorktree.id)
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
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
    await store.receive(\.archiveWorktreeConfirmed) {
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
    await store.receive(\.selectWorktree)
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

  private func makeRepository(id: String, worktrees: [Worktree]) -> Repository {
    Repository(
      id: id,
      rootURL: URL(fileURLWithPath: id),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }

  private func makeState(repositories: [Repository]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: repositories)
    state.repositoryRoots = repositories.map(\.rootURL)
    return state
  }
}
