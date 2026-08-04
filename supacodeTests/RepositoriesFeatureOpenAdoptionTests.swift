import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// `openRepositories` reporting what each requested path actually became.
///
/// The regression this guards: `repo open <existing-worktree>` used to answer
/// the CLI `ok: true` immediately, so it exited 0 whether or not anything was
/// adopted. Every path now resolves to an adopted id or an explanation.
@MainActor
struct RepositoriesFeatureOpenAdoptionTests {
  private let repoID: Repository.ID = "/tmp/open-repo"

  private var repositoryRoot: URL { URL(fileURLWithPath: repoID.rawValue) }
  private var worktreeDirectory: URL { URL(fileURLWithPath: "/tmp/open-repo/.worktrees/feature-x") }
  private var worktreeID: Worktree.ID { WorktreeID("\(repoID)/feature-x") }

  private func makeRepository() -> Repository {
    let mainWorktree = Worktree(
      id: WorktreeID("\(repoID)/main"),
      name: "main",
      detail: "detail",
      workingDirectory: repositoryRoot,
      repositoryRootURL: repositoryRoot,
    )
    let featureWorktree = Worktree(
      id: worktreeID,
      name: "feature/x",
      detail: ".worktrees/feature-x",
      workingDirectory: worktreeDirectory,
      repositoryRootURL: repositoryRoot,
    )
    return Repository(
      id: repoID,
      rootURL: repositoryRoot,
      name: "open-repo",
      worktrees: IdentifiedArray(uniqueElements: [mainWorktree, featureWorktree]),
      isGitRepository: true,
    )
  }

  private func makeStore(pendingOpen: [URL] = []) -> TestStoreOf<RepositoriesFeature> {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [makeRepository()])
    state.repositoryRoots = [repositoryRoot]
    state.pendingOpenRequests = pendingOpen
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
  }

  /// Drive the finish arm directly: the effect that precedes it does disk and
  /// git work that isn't what's under test here. The requested paths reach the
  /// handler through `pendingOpenRequests`, seeded via `makeStore`.
  private func finishOpen(
    _ store: TestStoreOf<RepositoriesFeature>,
    invalidRoots: [String] = []
  ) async {
    await store.send(
      .openRepositoriesFinished(
        [makeRepository()],
        failures: [],
        invalidRoots: invalidRoots,
        roots: [repositoryRoot]
      )
    )
  }

  @Test func openingAWorktreePathAdoptsAndSelectsIt() async {
    let store = makeStore(pendingOpen: [worktreeDirectory])

    await finishOpen(store)

    // Adoption is observable: the named worktree is now the selection.
    #expect(store.state.selectedWorktreeID == worktreeID)
    await store.finish()
  }

  @Test func openingAWorktreePathReportsTheWorktreeOutcome() async {
    let store = makeStore(pendingOpen: [worktreeDirectory])

    await finishOpen(store)

    // This payload is what the CLI ack reads to answer `repo open`.
    await store.receive(
      \.delegate.repositoriesOpened,
      [
        RepositoryOpenOutcome(
          requestedURL: worktreeDirectory,
          result: .worktree(id: worktreeID, repositoryID: repoID)
        )
      ]
    )
    await store.finish()
  }

  @Test func openingAPathInsideAWorktreeResolvesToThatWorktree() async {
    let nested = worktreeDirectory.appending(path: "Sources/App")
    let store = makeStore(pendingOpen: [nested])

    // `repo open <subdir>` has always worked; it must keep working, and now
    // resolve to the innermost container rather than reporting a failure.
    await finishOpen(store)

    await store.receive(
      \.delegate.repositoriesOpened,
      [
        RepositoryOpenOutcome(
          requestedURL: nested,
          result: .worktree(id: worktreeID, repositoryID: repoID)
        )
      ]
    )
    await store.finish()
  }

  @Test func pathMatchingNothingIsReportedAsAFailure() async {
    let stranger = URL(fileURLWithPath: "/tmp/somewhere-else")
    let store = makeStore(pendingOpen: [stranger])

    await finishOpen(store)

    // The core of the fix: no match means a reported failure, never silence.
    await store.receive(
      \.delegate.repositoriesOpened,
      [
        RepositoryOpenOutcome(
          requestedURL: stranger,
          result: .failed(
            message: "/tmp/somewhere-else didn't resolve to a repository or worktree Supacode could open."
          )
        )
      ]
    )
    await store.finish()
  }

  @Test func invalidRootIsReportedAsAFailure() async {
    let missing = URL(fileURLWithPath: "/tmp/definitely-not-here")
    let store = makeStore(pendingOpen: [missing])

    await finishOpen(store, invalidRoots: ["/tmp/definitely-not-here"])

    await store.receive(
      \.delegate.repositoriesOpened,
      [
        RepositoryOpenOutcome(
          requestedURL: missing,
          result: .failed(message: "Supacode couldn't read /tmp/definitely-not-here.")
        )
      ]
    )
    await store.finish()
  }

  @Test func openingTheRepositoryRootReportsARepositoryOutcome() async {
    let store = makeStore(pendingOpen: [repositoryRoot])

    await finishOpen(store)

    // A repo root resolves to the repository, not to one of its worktrees, so
    // opening it doesn't adopt (or select) an arbitrary worktree. `isNew` is
    // false because this repository was already open.
    await store.receive(
      \.delegate.repositoriesOpened,
      [
        RepositoryOpenOutcome(
          requestedURL: repositoryRoot,
          result: .repository(id: repoID, isNew: false)
        )
      ]
    )
    await store.finish()
  }

  @Test func openWithoutRequestedPathsEmitsNoOutcomes() async {
    let store = makeStore()

    // The GUI reload path registers no pending open, so it must not start
    // answering acks that were never registered.
    await finishOpen(store)
    await store.finish()
  }

  // MARK: - Surviving a cancelled load.

  /// Every load shares `CancelID.load` with `cancelInFlight: true`, so a periodic
  /// refresh (or a second `repo open`) cancels an open's load and
  /// `openRepositoriesFinished` never arrives. The pending request has to outlive
  /// that and be answered by whichever load does finish — otherwise the CLI
  /// blocks for the full 180s ack timeout and then reports failure for an open
  /// that actually succeeded.
  @Test func aRefreshLoadAnswersAnOpenWhoseOwnLoadWasCancelled() async {
    let store = makeStore(pendingOpen: [worktreeDirectory])

    // The refresh's completion action, not the open's.
    await store.send(
      .repositoriesLoaded([makeRepository()], failures: [], roots: [repositoryRoot], animated: false)
    )

    await store.receive(
      \.delegate.repositoriesOpened,
      [
        RepositoryOpenOutcome(
          requestedURL: worktreeDirectory,
          result: .worktree(id: worktreeID, repositoryID: repoID)
        )
      ]
    )
    #expect(store.state.selectedWorktreeID == worktreeID)
    await store.finish()
  }

  /// The verdict is paid exactly once: a later load must not re-answer an ack
  /// that has already been drained, which would resolve an unrelated command.
  @Test func aSecondLoadDoesNotReAnswerADrainedOpen() async {
    let store = makeStore(pendingOpen: [worktreeDirectory])

    await finishOpen(store)
    await store.receive(\.delegate.repositoriesOpened)
    #expect(store.state.pendingOpenRequests.isEmpty)

    // A subsequent refresh has nothing left owed, so it emits no outcomes.
    await store.send(
      .repositoriesLoaded([makeRepository()], failures: [], roots: [repositoryRoot], animated: false)
    )
    await store.finish()
  }

  /// Two `repo open` calls in a script land back-to-back; the second cancels the
  /// first's load, so one completion has to answer both.
  @Test func oneLoadAnswersEveryOpenStillOwedAVerdict() async {
    let stranger = URL(fileURLWithPath: "/tmp/somewhere-else")
    let store = makeStore(pendingOpen: [worktreeDirectory, stranger])

    await finishOpen(store)

    await store.receive(
      \.delegate.repositoriesOpened,
      [
        RepositoryOpenOutcome(
          requestedURL: worktreeDirectory,
          result: .worktree(id: worktreeID, repositoryID: repoID)
        ),
        RepositoryOpenOutcome(
          requestedURL: stranger,
          result: .failed(
            message: "/tmp/somewhere-else didn't resolve to a repository or worktree Supacode could open."
          )
        ),
      ]
    )
    await store.finish()
  }
}
