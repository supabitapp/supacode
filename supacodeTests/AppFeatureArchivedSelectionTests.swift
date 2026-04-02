import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct AppFeatureArchivedSelectionTests {
  @Test(.dependencies) func selectingArchivedWorktreesDoesNotClearLastFocused() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let worktree = Worktree(
      id: "/tmp/repo/wt1",
      name: "wt1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt1"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .worktree(worktree.id)
    let saved = LockIsolated<[Worktree.ID?]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveLastFocusedWorktreeID = { id in
        saved.withValue { $0.append(id) }
      }
      $0.terminalClient.send = { _ in }
      $0.worktreeInfoWatcher.send = { _ in }
    }

    await store.send(.repositories(.selectArchivedWorktrees)) {
      $0.repositories.selection = .archivedWorktrees
    }
    await store.receive(\.repositories.delegate.selectedWorktreeChanged)
    await store.finish()
    #expect(saved.value.isEmpty)
  }

  @Test(.dependencies) func repositoriesChangedPrunesArchivedWorktreesFromTerminalAndRunScriptStatus() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let activeWorktree = Worktree(
      id: "/tmp/repo/wt-active",
      name: "wt-active",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-active"),
      repositoryRootURL: rootURL
    )
    let archivedWorktree = Worktree(
      id: "/tmp/repo/wt-archived",
      name: "wt-archived",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-archived"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [activeWorktree, archivedWorktree])
    )
    var repositoriesState = RepositoriesFeature.State(repositories: [repository])
    repositoriesState.selection = .worktree(activeWorktree.id)
    repositoriesState.archivedWorktreeDates[archivedWorktree.id] = Date(timeIntervalSince1970: 1_000_000)
    var appState = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    appState.repositories.runScriptWorktreeIDs = [activeWorktree.id, archivedWorktree.id]
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.repositoriesChanged([repository])))) {
      $0.repositories.runScriptWorktreeIDs = [activeWorktree.id]
    }
    await store.finish()

    #expect(
      sentCommands.value == [
        .prune([activeWorktree.id])
      ]
    )
  }
}
