import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureRunScriptTests {
  @Test(.dependencies) func runScriptWithoutConfiguredScriptsOpensSettings() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let expectedRepositoryID = worktree.repositoryRootURL.path(percentEncoded: false)
    var settingsState = SettingsFeature.State()
    settingsState.repositorySummaries = [
      SettingsRepositorySummary(id: expectedRepositoryID, name: "repo")
    ]
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: settingsState
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.runScript)
    await store.receive(\.settings.setSelection)
    #expect(store.state.settings.selection == .repositoryScripts(expectedRepositoryID))
  }

  @Test(.dependencies) func runScriptRunsFirstRunKindScript() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev")
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(
      repositories: repositories,
      settings: SettingsFeature.State()
    )
    initialState.scripts = [definition]
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.runScript)
    await store.receive(\.runNamedScript) {
      $0.repositories.runningScriptsByWorktreeID = [worktree.id: [definition.id: definition.resolvedTintColor]]

    }
    await store.finish()

    #expect(sent.value.count == 1)
    guard case .runBlockingScript(let sentWorktree, let kind, let script) = sent.value.first else {
      Issue.record("Expected runBlockingScript command")
      return
    }
    #expect(sentWorktree == worktree)
    #expect(script == "npm run dev")
    guard case .script(let sentDefinition) = kind else {
      Issue.record("Expected .script kind")
      return
    }
    #expect(sentDefinition.kind == .run)
    #expect(sentDefinition.command == "npm run dev")
  }

  @Test(.dependencies) func runNamedScriptTracksRunningState() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let definition = ScriptDefinition(kind: .test, name: "Test", command: "npm test")
    var initialState = AppFeature.State(
      repositories: repositories,
      settings: SettingsFeature.State()
    )
    initialState.scripts = [definition]
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
    }

    await store.send(.runNamedScript(definition)) {
      $0.repositories.runningScriptsByWorktreeID = [worktree.id: [definition.id: definition.resolvedTintColor]]
    }
    await store.finish()
  }

  @Test(.dependencies) func runNamedScriptRejectsDuplicateRun() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev")
    var initialState = AppFeature.State(
      repositories: repositories,
      settings: SettingsFeature.State()
    )
    initialState.scripts = [definition]
    // Pre-populate running state to simulate an already-running script.
    initialState.repositories.runningScriptsByWorktreeID = [worktree.id: [definition.id: definition.resolvedTintColor]]
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    // Second run of the same script should be silently rejected.
    await store.send(.runNamedScript(definition))
    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func scriptCompletedRemovesFromTracking() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev")
    var repositoriesState = repositories
    repositoriesState.runningScriptsByWorktreeID = [worktree.id: [definition.id: definition.resolvedTintColor]]

    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(
      .repositories(
        .scriptCompleted(
          worktreeID: worktree.id,
          scriptID: definition.id,
          kind: .script(definition),
          exitCode: 0,
          tabId: nil
        )
      )
    ) {
      $0.repositories.runningScriptsByWorktreeID = [:]

    }
  }

  @Test(.dependencies) func stopRunScriptsCallsTerminalClient() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.stopRunScripts)
    await store.finish()

    #expect(sent.value.count == 1)
    guard case .stopRunScript(let sentWorktree) = sent.value.first else {
      Issue.record("Expected stopRunScript command")
      return
    }
    #expect(sentWorktree == worktree)
  }

  @Test(.dependencies) func stopScriptSendsTerminalCommand() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let definition = ScriptDefinition(kind: .test, name: "Test", command: "npm test")
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State(),
      ),
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.stopScript(definition))
    await store.finish()

    #expect(sent.value.count == 1)
    guard case .stopScript(let sentWorktree, let definitionID) = sent.value.first else {
      Issue.record("Expected stopScript command")
      return
    }
    #expect(sentWorktree == worktree)
    #expect(definitionID == definition.id)
  }

  @Test(.dependencies) func worktreeSettingsLoadedPopulatesScripts() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev")
    var settings = RepositorySettings.default
    settings.scripts = [definition]
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.worktreeSettingsLoaded(settings, worktreeID: worktree.id))
    #expect(store.state.scripts == [definition])
  }

  @Test(.dependencies) func scriptCompletedCleansUpOrphanedIDAfterScriptDeletion() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let definition = ScriptDefinition(kind: .test, name: "Test", command: "npm test")
    // Simulate a script that is running but has been removed from
    // the settings (e.g. user deleted it while it was executing).
    var repositoriesState = repositories
    repositoriesState.runningScriptsByWorktreeID = [worktree.id: [definition.id: definition.resolvedTintColor]]

    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }
    // Scripts array is empty — the definition was deleted from settings.
    #expect(store.state.scripts.isEmpty)

    await store.send(
      .repositories(
        .scriptCompleted(
          worktreeID: worktree.id,
          scriptID: definition.id,
          kind: .script(definition),
          exitCode: 0,
          tabId: nil
        )
      )
    ) {
      $0.repositories.runningScriptsByWorktreeID = [:]

    }
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
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    return repositoriesState
  }
}
