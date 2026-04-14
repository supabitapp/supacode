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
      SettingsRepositorySummary(id: expectedRepositoryID, name: "repo"),
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
      $0.repositories.runningScriptsByWorktreeID = [worktree.id: [definition.id]]
      $0.repositories.scriptTintColorByID = [definition.id: definition.tintColor]
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
      $0.repositories.runningScriptsByWorktreeID = [worktree.id: [definition.id]]
      $0.repositories.scriptTintColorByID = [definition.id: definition.tintColor]
    }
    await store.finish()
  }

  @Test(.dependencies) func testScriptRunsFirstTestKindScript() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let testScript = ScriptDefinition(kind: .test, name: "Test", command: "npm test")
    let runScript = ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev")
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(
      repositories: repositories,
      settings: SettingsFeature.State()
    )
    initialState.scripts = [runScript, testScript]
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.testScript)
    await store.receive(\.runNamedScript) {
      $0.repositories.runningScriptsByWorktreeID = [worktree.id: [testScript.id]]
      $0.repositories.scriptTintColorByID = [testScript.id: testScript.tintColor]
    }
    await store.finish()

    #expect(sent.value.count == 1)
    guard case .runBlockingScript(_, let kind, let script) = sent.value.first else {
      Issue.record("Expected runBlockingScript command")
      return
    }
    #expect(script == "npm test")
    guard case .script(let def) = kind else {
      Issue.record("Expected .script kind")
      return
    }
    #expect(def.kind == .test)
  }

  @Test(.dependencies) func testScriptWithNoTestScriptDoesNothing() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    var initialState = AppFeature.State(
      repositories: repositories,
      settings: SettingsFeature.State()
    )
    initialState.scripts = [ScriptDefinition(kind: .run, command: "npm start")]
    let store = TestStore(initialState: initialState) {
      AppFeature()
    }

    await store.send(.testScript)
  }

  @Test(.dependencies) func scriptCompletedRemovesFromTracking() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev")
    var repositoriesState = repositories
    repositoriesState.runningScriptsByWorktreeID = [worktree.id: [definition.id]]
    repositoriesState.scriptTintColorByID = [definition.id: definition.tintColor]
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
      $0.repositories.scriptTintColorByID = [:]
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

  @Test(.dependencies) func debugScriptRunsFirstDebugKindScript() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let debugDef = ScriptDefinition(kind: .debug, name: "Debug", command: "lldb app")
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(
      repositories: repositories,
      settings: SettingsFeature.State(),
    )
    initialState.scripts = [debugDef]
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.debugScript)
    await store.receive(\.runNamedScript) {
      $0.repositories.runningScriptsByWorktreeID = [worktree.id: [debugDef.id]]
      $0.repositories.scriptTintColorByID = [debugDef.id: debugDef.tintColor]
    }
    await store.finish()

    #expect(sent.value.count == 1)
    guard case .runBlockingScript(_, let kind, _) = sent.value.first else {
      Issue.record("Expected runBlockingScript command")
      return
    }
    guard case .script(let def) = kind else {
      Issue.record("Expected .script kind")
      return
    }
    #expect(def.kind == .debug)
  }

  @Test(.dependencies) func deployScriptRunsFirstDeployKindScript() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let deployDef = ScriptDefinition(kind: .deploy, name: "Deploy", command: "./deploy.sh")
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(
      repositories: repositories,
      settings: SettingsFeature.State(),
    )
    initialState.scripts = [deployDef]
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.deployScript)
    await store.receive(\.runNamedScript) {
      $0.repositories.runningScriptsByWorktreeID = [worktree.id: [deployDef.id]]
      $0.repositories.scriptTintColorByID = [deployDef.id: deployDef.tintColor]
    }
    await store.finish()

    #expect(sent.value.count == 1)
    guard case .runBlockingScript(_, let kind, _) = sent.value.first else {
      Issue.record("Expected runBlockingScript command")
      return
    }
    guard case .script(let def) = kind else {
      Issue.record("Expected .script kind")
      return
    }
    #expect(def.kind == .deploy)
  }

  @Test(.dependencies) func debugScriptWithNoDebugScriptDoesNothing() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    var initialState = AppFeature.State(
      repositories: repositories,
      settings: SettingsFeature.State(),
    )
    initialState.scripts = [ScriptDefinition(kind: .run, command: "npm start")]
    let store = TestStore(initialState: initialState) {
      AppFeature()
    }

    await store.send(.debugScript)
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
