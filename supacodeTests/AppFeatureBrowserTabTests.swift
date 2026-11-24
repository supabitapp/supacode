import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import SupacodeSettingsFeature
@testable import supacode

@MainActor
struct AppFeatureBrowserTabTests {
  private func makeWorktree() -> Worktree {
    Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func makeRepositoriesState(worktree: Worktree, selected: Bool) -> RepositoriesFeature.State {
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: [worktree]
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    if selected {
      repositoriesState.selection = .worktree(worktree.id)
    }
    repositoriesState.reconcileSidebarForTesting()
    return repositoriesState
  }

  private func makeStore(
    repositories: RepositoriesFeature.State,
    sent: LockIsolated<[TerminalClient.Command]>
  ) -> TestStoreOf<AppFeature> {
    TestStore(
      initialState: AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
  }

  @Test(.dependencies) func newBrowserTabOpensABlankBrowserBesideTheSelectedWorktreesTerminals() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(repositories: makeRepositoriesState(worktree: worktree, selected: true), sent: sent)

    await store.send(.newBrowserTab)
    await store.finish()

    #expect(sent.value == [.openBrowserTab(worktree, url: nil, placement: .beside, focusing: true)])
  }

  @Test(.dependencies) func newBrowserTabDoesNothingWithoutASelectedWorktree() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(repositories: makeRepositoriesState(worktree: worktree, selected: false), sent: sent)

    await store.send(.newBrowserTab)
    await store.finish()

    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func thePaletteCommandOpensABrowserTab() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(repositories: makeRepositoriesState(worktree: worktree, selected: true), sent: sent)
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.layoutCommand(.newBrowserTab))))
    await store.receive(\.newBrowserTab)
    await store.finish()

    #expect(sent.value == [.openBrowserTab(worktree, url: nil, placement: .beside, focusing: true)])
  }
}
