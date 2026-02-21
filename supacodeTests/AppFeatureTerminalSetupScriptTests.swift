import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@MainActor
struct AppFeatureTerminalSetupScriptTests {
  @Test(.dependencies) func newTerminalSendsCreateTabForSelectedWorktree() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(worktree: worktree, selected: true)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.newTerminal)
    await store.finish()
    #expect(sent.value == [.createTab(worktree)])
  }

  @Test(.dependencies) func worktreeCreatedTriggersEnsureInitialTab() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(worktree: worktree, selected: false)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.repositories(.delegate(.worktreeCreated(worktree))))
    await store.finish()
    #expect(
      sent.value == [
        .ensureInitialTab(worktree, focusing: false)
      ]
    )
  }

  @Test(.dependencies) func openWorktreeEditorSendsCreateTabWithInput() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(worktree: worktree, selected: true)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.openWorktree(.editor))
    await store.finish()
    #expect(
      sent.value == [
        .createTabWithInput(worktree, input: "$EDITOR")
      ]
    )
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

  private func makeRepositoriesState(
    worktree: Worktree,
    selected: Bool
  ) -> RepositoriesFeature.State {
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
    return repositoriesState
  }
}
