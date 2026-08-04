import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Worktree creation against a branch name that already exists.
///
/// Three outcomes, and the difference between them is the point of this suite:
/// a new name creates a branch (unchanged), an existing branch nobody holds can
/// be adopted but only on request, and a branch live in another worktree stays
/// refused. The last case can't be delegated to `wt sw`, which exits 0 and
/// prints the *other* worktree's path.
@MainActor
struct RepositoriesFeatureBranchReuseTests {
  private let repoID: Repository.ID = "/tmp/reuse-repo"

  /// Records what the creation stream was ultimately asked to build, so a test
  /// can tell "reused the branch" from "created a new one".
  private final class StreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [(name: String, baseRef: String, directory: URL?)] = []
    private(set) var pruneCount = 0

    func record(name: String, baseRef: String, directory: URL?) {
      lock.lock()
      defer { lock.unlock() }
      invocations.append((name, baseRef, directory))
    }

    func recordPrune() {
      lock.lock()
      defer { lock.unlock() }
      pruneCount += 1
    }

    var snapshot: [(name: String, baseRef: String, directory: URL?)] {
      lock.lock()
      defer { lock.unlock() }
      return invocations
    }
  }

  private func makeState() -> RepositoriesFeature.State {
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
      name: "reuse-repo",
      worktrees: IdentifiedArray(uniqueElements: [mainWorktree]),
      isGitRepository: true,
    )
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [repository.rootURL]
    return state
  }

  private func makeStore(
    availability: GitBranchAvailability,
    recorder: StreamRecorder
  ) -> TestStoreOf<RepositoriesFeature> {
    let store = TestStore(initialState: makeState()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isValidBranchName = { _, _ in true }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.branchAvailability = { _, _ in availability }
      $0.gitClient.pruneWorktrees = { _ in recorder.recordPrune() }
      $0.gitClient.createWorktreeStream = { name, _, _, _, _, baseRef, directoryOverride in
        recorder.record(name: name, baseRef: baseRef, directory: directoryOverride)
        return AsyncThrowingStream { continuation in
          continuation.yield(
            .finished(
              Worktree(
                id: WorktreeID("\(self.repoID)/\(name)"),
                name: name,
                detail: name,
                workingDirectory: URL(fileURLWithPath: "\(self.repoID)/\(name)"),
                repositoryRootURL: URL(fileURLWithPath: self.repoID.rawValue),
              )
            )
          )
          continuation.finish()
        }
      }
    }
    store.exhaustivity = .off
    return store
  }

  private func create(
    _ store: TestStoreOf<RepositoriesFeature>,
    branch: String = "feature/x",
    reuseExistingBranch: Bool = false
  ) async {
    await store.send(
      .createWorktreeInRepository(
        repositoryID: repoID,
        nameSource: .explicit(branch),
        baseRefSource: .explicit("origin/main"),
        fetchOrigin: false,
        reuseExistingBranch: reuseExistingBranch,
      )
    )
    await store.finish()
  }

  // MARK: - Unchanged behavior for new branches.

  @Test func newBranchCreatesWithTheRequestedBaseRef() async {
    let recorder = StreamRecorder()
    let store = makeStore(availability: .absent, recorder: recorder)

    await create(store)

    // The base ref still flows through, i.e. `wt sw --from origin/main` →
    // `git worktree add -b`. This is the path that must not change.
    #expect(recorder.snapshot.count == 1)
    #expect(recorder.snapshot.first?.name == "feature/x")
    #expect(recorder.snapshot.first?.baseRef == "origin/main")
    #expect(recorder.pruneCount == 0)
  }

  /// The reuse flag is permission, not instruction: with no existing branch it
  /// still creates a new one from the base ref.
  @Test func reuseFlagOnAnAbsentBranchStillCreatesANewBranch() async {
    let recorder = StreamRecorder()
    let store = makeStore(availability: .absent, recorder: recorder)

    await create(store, reuseExistingBranch: true)

    #expect(recorder.snapshot.first?.baseRef == "origin/main")
  }

  // MARK: - Existing unused branch.

  @Test func existingUnusedBranchIsRefusedWithoutTheReuseFlag() async {
    let recorder = StreamRecorder()
    let store = makeStore(availability: .reusable(stalePrunePath: nil), recorder: recorder)

    await store.send(
      .createWorktreeInRepository(
        repositoryID: repoID,
        nameSource: .explicit("feature/x"),
        baseRefSource: .explicit("origin/main"),
        fetchOrigin: false,
      )
    )
    await store.receive(\.createRandomWorktreeFailed)
    await store.finish()

    // Nothing was created, and the user was told why.
    #expect(recorder.snapshot.isEmpty)
    #expect(store.state.alert != nil)
  }

  @Test func existingUnusedBranchIsCheckedOutWithTheReuseFlag() async {
    let recorder = StreamRecorder()
    let store = makeStore(availability: .reusable(stalePrunePath: nil), recorder: recorder)

    await create(store, reuseExistingBranch: true)

    // No base ref: reuse checks out the branch's own tip, so `wt sw` gets no
    // `--from` and runs `git worktree add <path> <branch>`.
    #expect(recorder.snapshot.count == 1)
    #expect(recorder.snapshot.first?.name == "feature/x")
    #expect(recorder.snapshot.first?.baseRef == "")
    // `wt sw` refuses to adopt an existing branch without an explicit --path,
    // so the resolved directory has to be passed through.
    #expect(recorder.snapshot.first?.directory != nil)
    #expect(recorder.pruneCount == 0)
  }

  // MARK: - Stale worktree metadata.

  @Test func staleWorktreeMetadataIsPrunedBeforeReuse() async {
    let recorder = StreamRecorder()
    let store = makeStore(
      availability: .reusable(stalePrunePath: "/tmp/reuse-repo/.worktrees/gone"),
      recorder: recorder
    )

    await create(store, reuseExistingBranch: true)

    // Without the prune, git still counts the missing worktree as holding the
    // branch and the checkout fails.
    #expect(recorder.pruneCount == 1)
    #expect(recorder.snapshot.count == 1)
  }

  // MARK: - Branch checked out elsewhere.

  @Test func branchCheckedOutElsewhereIsRefused() async {
    let recorder = StreamRecorder()
    let store = makeStore(
      availability: .checkedOut(worktreePath: "/tmp/other/feature-x"),
      recorder: recorder
    )

    await store.send(
      .createWorktreeInRepository(
        repositoryID: repoID,
        nameSource: .explicit("feature/x"),
        baseRefSource: .explicit("origin/main"),
        fetchOrigin: false,
      )
    )
    await store.receive(\.createRandomWorktreeFailed)
    await store.finish()

    #expect(recorder.snapshot.isEmpty)
  }

  /// The refusal is not overridable: asking to reuse a branch that's live in
  /// another worktree must still fail rather than silently hand back that
  /// worktree, which is exactly what `wt sw` would do on its own.
  @Test func branchCheckedOutElsewhereIsRefusedEvenWithTheReuseFlag() async {
    let recorder = StreamRecorder()
    let store = makeStore(
      availability: .checkedOut(worktreePath: "/tmp/other/feature-x"),
      recorder: recorder
    )

    await store.send(
      .createWorktreeInRepository(
        repositoryID: repoID,
        nameSource: .explicit("feature/x"),
        baseRefSource: .explicit("origin/main"),
        fetchOrigin: false,
        reuseExistingBranch: true,
      )
    )
    await store.receive(\.createRandomWorktreeFailed)
    await store.finish()

    #expect(recorder.snapshot.isEmpty)
  }

  @Test func checkedOutMessageNamesTheOccupyingWorktree() {
    let message = GitBranchAvailability.checkedOutMessage(
      branch: "feature/x",
      worktreePath: "/tmp/other/feature-x"
    )
    #expect(message.contains("feature/x"))
    #expect(message.contains("/tmp/other/feature-x"))
  }
}
