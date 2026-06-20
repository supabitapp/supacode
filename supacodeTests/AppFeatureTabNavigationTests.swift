import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import supacode

@MainActor
struct AppFeatureTabNavigationTests {
  @Test(.dependencies) func showNextTabForwardsNextTabBinding() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.showNextTab)
    await store.finish()
    #expect(sent.value == [.performBindingAction(worktree, action: "next_tab")])
  }

  @Test(.dependencies) func showPreviousTabForwardsPreviousTabBinding() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.showPreviousTab)
    await store.finish()
    #expect(sent.value == [.performBindingAction(worktree, action: "previous_tab")])
  }

  @Test(.dependencies) func tabNavigationWithoutSelectionIsNoop() async {
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in
        Issue.record("terminalClient.send should not be called without a selected worktree")
      }
    }

    await store.send(.showNextTab)
    await store.send(.showPreviousTab)
    await store.finish()
  }

  private func makeWorktree() -> Worktree {
    Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func makeRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: [worktree]
    )
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    state.selection = .worktree(worktree.id)
    return state
  }
}
