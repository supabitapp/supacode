import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct AppFeatureTerminalSetupScriptTests {
  @Test(.dependencies) func newTerminalConsumesSetupScriptAndSendsCreateTabWithFlag() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: true
    )
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
    await store.send(.terminalEvent(.setupScriptConsumed(worktreeID: worktree.id)))
    await store.receive(\.repositories.consumeSetupScript) {
      $0.repositories.pendingSetupScriptWorktreeIDs.remove(worktree.id)
    }
    await store.finish()
    #expect(sent.value == [.createTab(worktree, runSetupScriptIfNew: true, id: nil)])
  }

  @Test(.dependencies) func newTerminalWithoutSetupScriptDoesNotConsume() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: false,
      selected: true
    )
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
    #expect(sent.value == [.createTab(worktree, runSetupScriptIfNew: false, id: nil)])
  }

  @Test(.dependencies) func tabCreatedDoesNotConsumeSetupScript() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: true
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.terminalEvent(.tabCreated(worktreeID: worktree.id)))
    #expect(store.state.repositories.pendingSetupScriptWorktreeIDs.contains(worktree.id))
    await store.finish()
  }

  @Test(.dependencies) func setupScriptConsumedEventClearsPending() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: true
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.terminalEvent(.setupScriptConsumed(worktreeID: worktree.id)))
    await store.receive(\.repositories.consumeSetupScript) {
      $0.repositories.pendingSetupScriptWorktreeIDs.remove(worktree.id)
    }
    await store.finish()
  }

  @Test(.dependencies) func worktreeCreatedTriggersEnsureInitialTabWithSetupScriptFlag() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: false
    )
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
        .ensureInitialTab(worktree, runSetupScriptIfNew: true, focusing: false)
      ]
    )
  }

  @Test(.dependencies) func worktreeCreatedSkipsSetupScriptFlagWhenNotPending() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: false,
      selected: false
    )
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
        .ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false)
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
    pendingSetupScript: Bool,
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
    if pendingSetupScript {
      repositoriesState.pendingSetupScriptWorktreeIDs = [worktree.id]
    }
    return repositoriesState
  }
}
