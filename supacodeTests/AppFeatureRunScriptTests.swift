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
    initialState.repoScripts = [definition]
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.runScript)
    await store.receive(\.runNamedScript)
    await store.finish()

    // No optimistic `runningScripts` write: the row reconciles from the
    // terminal's row projection once the script tab is tracked.
    #expect(store.state.repositories.sidebarItems[id: worktree.id]?.runningScripts.isEmpty == true)
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

  @Test(.dependencies) func projectionAddsMissedRunningScript() async {
    // A projection carrying a script the row doesn't track (e.g. the start
    // landed before the row existed) reconciles the row to terminal truth.
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev")
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(
      .terminalEvent(.worktreeProjectionChanged(worktree.id, makeProjection(scripts: [definition])))
    )
    await store.receive(\.repositories.sidebarItems) {
      $0.repositories.sidebarItems[id: worktree.id]?.hasTerminalProjection = true
      $0.repositories.sidebarItems[id: worktree.id]?.runningScripts[id: definition.id] =
        .init(id: definition.id, tint: definition.resolvedTintColor)
      $0.repositories.applyPostReduceCacheRecomputes()
    }
  }

  @Test(.dependencies) func projectionClearsPhantomRunningScript() async {
    // A projection with no tracked scripts clears a stale row entry, so the
    // toolbar can't keep offering "Stop" for a process that's gone (#573).
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev")
    var repositoriesState = makeRepositoriesState(worktree: worktree)
    repositoriesState.sidebarItems[id: worktree.id]?.runningScripts[id: definition.id] =
      .init(id: definition.id, tint: definition.resolvedTintColor)
    repositoriesState.reconcileSidebarForTesting()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(
      .terminalEvent(.worktreeProjectionChanged(worktree.id, makeProjection(scripts: [])))
    )
    await store.receive(\.repositories.sidebarItems) {
      $0.repositories.sidebarItems[id: worktree.id]?.hasTerminalProjection = true
      $0.repositories.sidebarItems[id: worktree.id]?.runningScripts.removeAll()
      $0.repositories.applyPostReduceCacheRecomputes()
    }
  }

  @Test(.dependencies) func runNamedScriptRejectsDuplicateRun() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev")
    var initialState = AppFeature.State(
      repositories: repositories,
      settings: SettingsFeature.State()
    )
    initialState.repoScripts = [definition]
    // Pre-populate running state to simulate an already-running script.
    initialState.repositories.sidebarItems[id: worktree.id]?.runningScripts[id: definition.id] =
      .init(id: definition.id, tint: definition.resolvedTintColor)
    initialState.repositories.applyPostReduceCacheRecomputes()
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

  @Test(.dependencies) func scriptCompletedLeavesTrackingToProjection() async {
    // Completion does not mutate `runningScripts`; the terminal's row
    // projection is the single writer and reconciles the removal itself.
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev")
    var repositoriesState = makeRepositoriesState(worktree: worktree)
    repositoriesState.sidebarItems[id: worktree.id]?.runningScripts[id: definition.id] =
      .init(id: definition.id, tint: definition.resolvedTintColor)
    // Re-reconcile after the ad-hoc runningScripts seed so the sidebar
    // structure cache reflects the seeded state. Otherwise the post-reduce
    // hook would surface a phantom structure mutation on the first dispatch.
    repositoriesState.reconcileSidebarForTesting()

    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(
      .terminalEvent(
        .blockingScriptCompleted(
          worktreeID: worktree.id,
          kind: .script(definition),
          exitCode: 0,
          tabId: nil
        )
      )
    )
    await store.receive(\.repositories.scriptCompleted)
    #expect(
      store.state.repositories.sidebarItems[id: worktree.id]?.runningScripts[id: definition.id] != nil
    )
  }

  @Test(.dependencies) func projectionStripsRunningScriptsForArchivedRow() async {
    // Mirrors `reconcileSidebarItems`: archived rows render no running-state
    // dots, so terminal truth must not re-inject them through the projection.
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev")
    let repositoriesState = makeArchivedRepositoriesState(worktree: worktree)
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(
      .terminalEvent(.worktreeProjectionChanged(worktree.id, makeProjection(scripts: [definition])))
    )
    await store.receive(\.repositories.sidebarItems) {
      $0.repositories.sidebarItems[id: worktree.id]?.hasTerminalProjection = true
      $0.repositories.applyPostReduceCacheRecomputes()
    }
    #expect(
      store.state.repositories.sidebarItems[id: worktree.id]?.runningScripts.isEmpty == true
    )
  }

  @Test(.dependencies) func projectionKeepsRunningScriptsForArchivedDeletingRow() async {
    // The strip's `.deletingScript` exception: a row mid-delete keeps its
    // running-state dots, mirroring `reconcileSidebarItems`.
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev")
    var repositoriesState = makeArchivedRepositoriesState(worktree: worktree)
    repositoriesState.sidebarItems[id: worktree.id]?.lifecycle = .deletingScript
    repositoriesState.applyPostReduceCacheRecomputes()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(
      .terminalEvent(.worktreeProjectionChanged(worktree.id, makeProjection(scripts: [definition])))
    )
    await store.receive(\.repositories.sidebarItems) {
      $0.repositories.sidebarItems[id: worktree.id]?.hasTerminalProjection = true
      $0.repositories.sidebarItems[id: worktree.id]?.runningScripts[id: definition.id] =
        .init(id: definition.id, tint: definition.resolvedTintColor)
      $0.repositories.applyPostReduceCacheRecomputes()
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
    #expect(store.state.repoScripts == [definition])
  }

  @Test(.dependencies) func scriptCompletedFailureAlertsWithoutTrackedRow() async {
    // The failure alert must not depend on the row mirror still tracking the
    // script: the projection may reconcile the removal before the completion
    // event lands (#573).
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev")
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off
    #expect(store.state.repositories.sidebarItems[id: worktree.id]?.runningScripts.isEmpty == true)

    await store.send(
      .repositories(
        .scriptCompleted(
          worktreeID: worktree.id,
          kind: .script(definition),
          exitCode: 143,
          tabId: nil
        )
      )
    )
    #expect(store.state.repositories.alert != nil)
  }

  @Test(.dependencies) func allScriptsMergesRepoAndGlobalScripts() {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let repoScript = ScriptDefinition(kind: .run, name: "Dev", command: "npm run dev")
    let globalScript = ScriptDefinition(kind: .custom, name: "Lint Repo", command: "make lint")
    var initialState = AppFeature.State(
      repositories: repositories,
      settings: SettingsFeature.State()
    )
    initialState.repoScripts = [repoScript]
    initialState.globalScripts = [globalScript]

    #expect(initialState.allScripts == [repoScript, globalScript])
    #expect(initialState.primaryScript == repoScript)
  }

  @Test(.dependencies) func runNamedScriptInvokesGlobalScript() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let globalScript = ScriptDefinition(kind: .custom, name: "Format", command: "swift-format")
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(
      repositories: repositories,
      settings: SettingsFeature.State()
    )
    initialState.globalScripts = [globalScript]
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.runNamedScript(globalScript))
    await store.finish()

    #expect(sent.value.count == 1)
    guard case .runBlockingScript(_, let kind, let script) = sent.value.first else {
      Issue.record("Expected runBlockingScript command")
      return
    }
    #expect(script == "swift-format")
    guard case .script(let sentDefinition) = kind else {
      Issue.record("Expected .script kind")
      return
    }
    #expect(sentDefinition.id == globalScript.id)
  }

  @Test(.dependencies) func settingsChangedSyncsGlobalScripts() async {
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let globalScript = ScriptDefinition(kind: .custom, name: "Deploy", command: "fly deploy")
    var settings = GlobalSettings.default
    settings.globalScripts = [globalScript]

    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.settings(.delegate(.settingsChanged(settings))))
    #expect(store.state.globalScripts == [globalScript])
    #expect(store.state.allScripts == [globalScript])
  }

  @Test(.dependencies) func allScriptsDeduplicatesByIDPreferringRepo() {
    let sharedID = UUID()
    let repoScript = ScriptDefinition(id: sharedID, kind: .run, name: "Repo", command: "npm run dev")
    let globalScript = ScriptDefinition(id: sharedID, kind: .custom, name: "Global", command: "echo global")
    let worktree = makeWorktree()
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    initialState.repoScripts = [repoScript]
    initialState.globalScripts = [globalScript]

    #expect(initialState.allScripts == [repoScript])
  }

  @Test(.dependencies) func settingsChangedDispatchesPruneRecencyOnGlobalScriptChange() async {
    // Adding/removing globals must scrub orphaned recency entries; otherwise
    // a removed script's runScript/stopScript palette IDs would linger forever.
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    var settings = GlobalSettings.default
    settings.globalScripts = [ScriptDefinition(kind: .custom, name: "Lint", command: "make lint")]
    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.receive(\.commandPalette.pruneRecency)
  }

  @Test(.dependencies) func runNamedScriptResolvesCollidingGlobalToRepoScript() async {
    let sharedID = UUID()
    let repoScript = ScriptDefinition(id: sharedID, kind: .test, name: "Repo", command: "echo repo")
    let collidingGlobal = ScriptDefinition(id: sharedID, kind: .custom, name: "Global", command: "echo global")
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    initialState.repoScripts = [repoScript]
    initialState.globalScripts = [collidingGlobal]
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    // The view passes the colliding global, but the reducer must resolve through allScripts
    // and run the repo script's command instead.
    await store.send(.runNamedScript(collidingGlobal))
    await store.finish()

    let runCommands = sent.value.compactMap { command -> ScriptDefinition? in
      if case .runBlockingScript(_, .script(let def), _) = command { return def }
      return nil
    }
    #expect(runCommands.count == 1)
    #expect(runCommands.first?.command == "echo repo")
  }

  @Test(.dependencies) func paletteRunScriptResolvesCollidingGlobalToRepoScript() async {
    let sharedID = UUID()
    let repoScript = ScriptDefinition(id: sharedID, kind: .test, name: "Repo", command: "echo repo")
    let collidingGlobal = ScriptDefinition(id: sharedID, kind: .custom, name: "Global", command: "echo global")
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    initialState.repoScripts = [repoScript]
    initialState.globalScripts = [collidingGlobal]
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    // Palette delegate route — same collision-resolution invariant as direct dispatch.
    await store.send(.commandPalette(.delegate(.runScript(collidingGlobal))))
    await store.finish()

    let runCommands = sent.value.compactMap { command -> ScriptDefinition? in
      if case .runBlockingScript(_, .script(let def), _) = command { return def }
      return nil
    }
    #expect(runCommands.count == 1)
    #expect(runCommands.first?.command == "echo repo")
  }

  @Test(.dependencies) func runNamedScriptIgnoresSinceDeletedScriptID() async {
    let orphan = ScriptDefinition(kind: .custom, name: "Stale", command: "echo stale")
    let worktree = makeWorktree()
    let repositories = makeRepositoriesState(worktree: worktree)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    initialState.repoScripts = []
    initialState.globalScripts = []
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    // Stale view binding from before a remove: must drop, not run.
    await store.send(.runNamedScript(orphan))
    await store.finish()

    #expect(sent.value.isEmpty)
    #expect(store.state.repositories.sidebarItems[id: worktree.id]?.runningScripts.isEmpty == true)
  }

  @Test(.dependencies) func primaryScriptIgnoresGlobalRunInjectedViaDecode() throws {
    // Globals are nominally always `.custom`, but a hand-edited settings.json
    // could ship a `.run` global. The merge order (repo wins) must prevent
    // such an entry from hijacking the primary toolbar action.
    let json = #"""
      {"id":"\#(UUID().uuidString)","kind":"run","name":"Sneaky","command":"rm -rf /"}
      """#
    let injected = try JSONDecoder().decode(ScriptDefinition.self, from: Data(json.utf8))
    let repoScript = ScriptDefinition(kind: .run, name: "Real", command: "npm run dev")
    let worktree = makeWorktree()
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    initialState.repoScripts = [repoScript]
    initialState.globalScripts = [injected]

    #expect(initialState.primaryScript == repoScript)
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

  private func makeProjection(scripts: [ScriptDefinition]) -> WorktreeRowProjection {
    var runningScripts: IdentifiedArrayOf<SidebarItemFeature.State.RunningScript> = []
    for script in scripts {
      runningScripts.updateOrAppend(.init(id: script.id, tint: script.resolvedTintColor))
    }
    return WorktreeRowProjection(
      surfaceIDs: [],
      isProgressBusy: false,
      hasUnseenNotifications: false,
      notifications: [],
      runningScripts: runningScripts
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
    repositoriesState.reconcileSidebarForTesting()
    return repositoriesState
  }

  /// `makeRepositoriesState` with the worktree seeded into the archived bucket.
  private func makeArchivedRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    var repositoriesState = makeRepositoriesState(worktree: worktree)
    let repositoryID = RepositoryID(worktree.repositoryRootURL.path(percentEncoded: false))
    repositoriesState.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: worktree.id,
        in: repositoryID,
        bucket: .archived,
        item: .init(archivedAt: Date(timeIntervalSince1970: 1_000_000))
      )
    }
    repositoriesState.reconcileSidebarForTesting()
    return repositoriesState
  }
}
