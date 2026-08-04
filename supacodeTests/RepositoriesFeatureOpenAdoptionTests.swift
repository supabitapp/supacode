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

  private func makeStore() -> TestStoreOf<RepositoriesFeature> {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [makeRepository()])
    state.repositoryRoots = [repositoryRoot]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
  }

  /// Drive the finish arm directly: the effect that precedes it does disk and
  /// git work that isn't what's under test here.
  private func finishOpen(
    _ store: TestStoreOf<RepositoriesFeature>,
    requested: [URL],
    invalidRoots: [String] = []
  ) async {
    await store.send(
      .openRepositoriesFinished(
        [makeRepository()],
        failures: [],
        invalidRoots: invalidRoots,
        roots: [repositoryRoot],
        requested: requested
      )
    )
  }

  @Test func openingAWorktreePathAdoptsAndSelectsIt() async {
    let store = makeStore()

    await finishOpen(store, requested: [worktreeDirectory])

    // Adoption is observable: the named worktree is now the selection.
    #expect(store.state.selectedWorktreeID == worktreeID)
    await store.finish()
  }

  @Test func openingAWorktreePathReportsTheWorktreeOutcome() async {
    let store = makeStore()

    await finishOpen(store, requested: [worktreeDirectory])

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
    let store = makeStore()
    let nested = worktreeDirectory.appending(path: "Sources/App")

    // `repo open <subdir>` has always worked; it must keep working, and now
    // resolve to the innermost container rather than reporting a failure.
    await finishOpen(store, requested: [nested])

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
    let store = makeStore()
    let stranger = URL(fileURLWithPath: "/tmp/somewhere-else")

    await finishOpen(store, requested: [stranger])

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
    let store = makeStore()
    let missing = URL(fileURLWithPath: "/tmp/definitely-not-here")

    await finishOpen(
      store,
      requested: [missing],
      invalidRoots: ["/tmp/definitely-not-here"]
    )

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
    let store = makeStore()

    await finishOpen(store, requested: [repositoryRoot])

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

    // The GUI reload path passes no `requested`, so it must not start
    // answering acks that were never registered.
    await finishOpen(store, requested: [])
    await store.finish()
  }
}
