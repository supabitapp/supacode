import ComposableArchitecture
import Darwin
import DependenciesTestSupport
import Foundation
import OrderedCollections
import Sharing
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
@Suite(.serialized)
struct AppFeatureDeeplinkTests {
  // MARK: - Routing after load.

  @Test(.dependencies) func selectWorktreeDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .select)))
    await store.receive(\.repositories.selectWorktree)
  }

  @Test(.dependencies) func runWorktreeDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .run)))
    await store.receive(\.repositories.selectWorktree)
    await store.receive(\.runScript)
  }

  @Test(.dependencies) func pinWorktreeDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .pin)))
    await store.receive(\.repositories.pinWorktree)
  }

  @Test(.dependencies) func unpinWorktreeDeeplink() async {
    let worktree = makeWorktree()
    var repositories = makeRepositoriesState(worktree: worktree)
    let repositoryID = repositories.repositories.first?.id
    repositories.$sidebar.withLock { sidebar in
      guard let repositoryID else { return }
      sidebar.sections[repositoryID, default: .init()]
        .buckets[.pinned, default: .init()]
        .items[worktree.id] = .init()
    }
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .unpin)))
    await store.receive(\.repositories.unpinWorktree)
  }

  @Test(.dependencies) func archiveWorktreeDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .archive)))
    await store.receive(\.repositories.requestArchiveWorktree)
  }

  @Test(.dependencies) func archiveWorktreeDeeplinkWithUnknownIDShowsAlert() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: "/nonexistent", action: .archive)))
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func deleteWorktreeDeeplinkShowsConfirmation() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .delete)))
    #expect(store.state.deeplinkInputConfirmation?.message == .confirmation("Delete worktree \"wt-1\"?"))
    #expect(store.state.deeplinkInputConfirmation?.action == .delete)
  }

  @Test(.dependencies) func deleteWorktreeDeeplinkSkipsConfirmationWhenSettingEnabled() async {
    let worktree = makeWorktree()
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .always
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings,
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .delete)))
    #expect(store.state.deeplinkInputConfirmation == nil)
    await store.receive(\.repositories.deleteSidebarItemConfirmed)
  }

  @Test(.dependencies) func deleteWorktreeDeeplinkConfirmationAcceptedSendsDeleteConfirmed() async {
    let worktree = makeWorktree()
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.deeplinkInputConfirmation = DeeplinkInputConfirmationFeature.State(
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      repositoryName: "repo",
      message: .confirmation("Delete worktree \"wt-1\"?"),
      action: .delete,
    )
    let store = TestStore(initialState: initialState) {
      AppFeature()
    }
    store.exhaustivity = .off

    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(
        .deeplinkInputConfirmation(
          .presented(
            .delegate(
              .confirm(worktreeID: worktree.id, action: .delete, alwaysAllow: false)))
        )
      ) {
        $0.deeplinkInputConfirmation = nil
      }
    }
    await store.receive(\.repositories.deleteSidebarItemConfirmed)
    await store.finish()
  }

  @Test(.dependencies) func deleteMainWorktreeDeeplinkShowsDeleteNotAllowed() async {
    let mainWorktree = makeWorktree(id: "/tmp/repo", name: "repo")
    let store = makeStore(worktree: mainWorktree)

    await store.send(.deeplink(.worktree(id: mainWorktree.id, action: .delete)))
    #expect(store.state.deeplinkInputConfirmation == nil)
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func deleteFolderDeeplinkRoutesToFolderAlertPipeline() async {
    // Regression: folders have a synthetic main-worktree
    // (`workingDirectory == rootURL`), so the `isMainWorktree` gate
    // in the deeplink handler used to reject them with a
    // "main worktree not allowed" alert — making folders
    // undeletable via deeplink. Fix routes folder targets to
    // `.requestDeleteSidebarItems([target])` so the 3-button
    // folder confirmation fires.
    let folderRoot = "/tmp/folder-deeplink-\(UUID().uuidString)"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: folderRoot,
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: [folderWorktree],
      isGitRepository: false
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [folderRepo]
    repositoriesState.repositoryRoots = [folderURL]
    repositoriesState.isInitialLoadComplete = true
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: folderWorktree.id, action: .delete)))
    await store.receive(\.repositories.requestDeleteSidebarItems)
    #expect(store.state.repositories.alert != nil, "folder alert should be presented")
  }

  @Test(.dependencies) func deleteWorktreeDeeplinkWithUnknownIDShowsAlert() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: "/nonexistent", action: .delete)))
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func unarchiveWorktreeDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .unarchive)))
    await store.receive(\.repositories.unarchiveWorktree)
  }

  @Test(.dependencies) func stopWorktreeDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .stop)))
    await store.receive(\.repositories.selectWorktree)
    await store.receive(\.stopRunScripts)
  }

  // MARK: - Named script deeplinks.

  @Test(.dependencies) func runScriptDeeplinkShowsConfirmation() async {
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .test, name: "Test", command: "npm test")
    let rootURL = worktree.repositoryRootURL
    @Shared(.repositorySettings(rootURL)) var persisted = .default
    $persisted.withLock { $0.scripts = [definition] }
    defer { $persisted.withLock { $0.scripts = [] } }
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .runScript(scriptID: definition.id))))
    #expect(store.state.deeplinkInputConfirmation?.message == .command("npm test"))
    #expect(store.state.deeplinkInputConfirmation?.action == .runScript(scriptID: definition.id))
  }

  @Test(.dependencies) func runScriptDeeplinkSkipsConfirmationWhenPolicyAllows() async {
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .test, name: "Test", command: "npm test")
    let rootURL = worktree.repositoryRootURL
    @Shared(.repositorySettings(rootURL)) var persisted = .default
    $persisted.withLock { $0.scripts = [definition] }
    defer { $persisted.withLock { $0.scripts = [] } }
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .always
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .runScript(scriptID: definition.id))))
    await store.finish()

    #expect(store.state.deeplinkInputConfirmation == nil)
    let hasRun = sent.value.contains(where: {
      if case .runBlockingScript(_, .script(let sentDefinition), _) = $0 {
        return sentDefinition.id == definition.id
      }
      return false
    })
    #expect(hasRun)
  }

  @Test(.dependencies) func runScriptDeeplinkWithUnknownScriptShowsAlert() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .runScript(scriptID: UUID()))))
    #expect(store.state.alert != nil)
    #expect(store.state.deeplinkInputConfirmation == nil)
  }

  @Test(.dependencies) func stopScriptDeeplinkSendsStopCommand() async {
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .test, name: "Test", command: "npm test")
    let rootURL = worktree.repositoryRootURL
    @Shared(.repositorySettings(rootURL)) var persisted = .default
    $persisted.withLock { $0.scripts = [definition] }
    defer { $persisted.withLock { $0.scripts = [] } }
    var repositories = makeRepositoriesState(worktree: worktree)
    repositories.runningScriptsByWorktreeID = [worktree.id: [definition.id]]
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .stopScript(scriptID: definition.id))))
    await store.finish()

    #expect(store.state.deeplinkInputConfirmation == nil)
    let hasStop = sent.value.contains(where: {
      if case .stopScript(_, let definitionID) = $0 { return definitionID == definition.id }
      return false
    })
    #expect(hasStop)
  }

  @Test(.dependencies) func stopScriptDeeplinkWithUnknownScriptShowsAlert() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .stopScript(scriptID: UUID()))))
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func stopScriptDeeplinkWhenNotRunningShowsAlert() async {
    // A user running `supacode worktree stop --script <uuid>` for a script
    // that isn't currently running should get an explicit alert, not a
    // silent success that misleads the CLI into reporting ok:true.
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .test, name: "Test", command: "npm test")
    let rootURL = worktree.repositoryRootURL
    @Shared(.repositorySettings(rootURL)) var persisted = .default
    $persisted.withLock { $0.scripts = [definition] }
    defer { $persisted.withLock { $0.scripts = [] } }
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
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .stopScript(scriptID: definition.id))))
    #expect(store.state.alert != nil)
    let didStop = sent.value.contains(where: {
      if case .stopScript = $0 { return true }
      return false
    })
    #expect(!didStop)
  }

  @Test(.dependencies) func runScriptDeeplinkWithEmptyCommandShowsAlert() async {
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .test, name: "Test", command: "   ")
    let rootURL = worktree.repositoryRootURL
    @Shared(.repositorySettings(rootURL)) var persisted = .default
    $persisted.withLock { $0.scripts = [definition] }
    defer { $persisted.withLock { $0.scripts = [] } }
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .always
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .runScript(scriptID: definition.id))))
    #expect(store.state.alert != nil)
    let didRun = sent.value.contains(where: {
      if case .runBlockingScript = $0 { return true }
      return false
    })
    #expect(!didRun)
  }

  @Test(.dependencies) func runScriptDeeplinkWhenAlreadyRunningShowsAlert() async {
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .test, name: "Test", command: "npm test")
    let rootURL = worktree.repositoryRootURL
    @Shared(.repositorySettings(rootURL)) var persisted = .default
    $persisted.withLock { $0.scripts = [definition] }
    defer { $persisted.withLock { $0.scripts = [] } }
    var repositories = makeRepositoriesState(worktree: worktree)
    repositories.runningScriptsByWorktreeID = [worktree.id: [definition.id]]
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .always
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositories, settings: settings)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .runScript(scriptID: definition.id))))
    #expect(store.state.alert != nil)
    let didRun = sent.value.contains(where: {
      if case .runBlockingScript = $0 { return true }
      return false
    })
    #expect(!didRun)
  }

  @Test(.dependencies) func runScriptConfirmationAcceptedDispatchesCommand() async {
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .test, name: "Test", command: "npm test")
    let rootURL = worktree.repositoryRootURL
    @Shared(.repositorySettings(rootURL)) var persisted = .default
    $persisted.withLock { $0.scripts = [definition] }
    defer { $persisted.withLock { $0.scripts = [] } }
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    initialState.deeplinkInputConfirmation = DeeplinkInputConfirmationFeature.State(
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      repositoryName: "repo",
      message: .command(definition.command),
      action: .runScript(scriptID: definition.id)
    )
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(
        .deeplinkInputConfirmation(
          .presented(
            .delegate(
              .confirm(worktreeID: worktree.id, action: .runScript(scriptID: definition.id), alwaysAllow: false)))
        )
      ) {
        $0.deeplinkInputConfirmation = nil
      }
    }
    await store.finish()

    let hasRun = sent.value.contains(where: {
      if case .runBlockingScript(_, .script(let sentDefinition), _) = $0 {
        return sentDefinition.id == definition.id
      }
      return false
    })
    #expect(hasRun)
  }

  @Test(.dependencies) func stopScriptSocketDeeplinkSendsErrorWhenNotRunning() async {
    // Regression guard: stopping a script that exists but isn't running
    // must surface an error on the socket responseFD so the CLI exits
    // non-zero instead of reporting a false positive.
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .test, name: "Test", command: "npm test")
    let rootURL = worktree.repositoryRootURL
    @Shared(.repositorySettings(rootURL)) var persisted = .default
    $persisted.withLock { $0.scripts = [definition] }
    defer { $persisted.withLock { $0.scripts = [] } }
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .stopScript(scriptID: definition.id)),
        source: .socket,
        responseFD: writeFD
      )
    )
    await store.finish()

    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == false)
    #expect((response?["error"] as? String)?.isEmpty == false)
  }

  @Test(.dependencies) func runScriptSocketDeeplinkStoresResponseFDInConfirmation() async {
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .test, name: "Test", command: "npm test")
    let rootURL = worktree.repositoryRootURL
    @Shared(.repositorySettings(rootURL)) var persisted = .default
    $persisted.withLock { $0.scripts = [definition] }
    defer { $persisted.withLock { $0.scripts = [] } }
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .never
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .runScript(scriptID: definition.id)),
        source: .socket,
        responseFD: 42
      )
    )
    #expect(store.state.deeplinkInputConfirmation?.responseFD == 42)
    #expect(store.state.deeplinkInputConfirmation?.action == .runScript(scriptID: definition.id))
  }

  // MARK: - Help deeplink.

  @Test(.dependencies) func helpDeeplinkSetsReferenceRequested() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.help)) {
      $0.isDeeplinkReferenceRequested = true
    }
  }

  @Test(.dependencies) func deeplinkReferenceOpenedResetsFlag() async {
    let worktree = makeWorktree()
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.isDeeplinkReferenceRequested = true
    let store = TestStore(initialState: initialState) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.deeplinkReferenceOpened) {
      $0.isDeeplinkReferenceRequested = false
    }
  }

  // MARK: - Destructive deeplink actions.

  @Test(.dependencies) func tabDestroyShowsConfirmationWhenSettingDisabled() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .tabDestroy(tabID: tabUUID))))
    #expect(store.state.deeplinkInputConfirmation != nil)
  }

  @Test(.dependencies) func tabDestroySkipsConfirmationWhenSettingEnabled() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .always
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings,
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
      $0.terminalClient.tabExists = { _, _ in true }
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .tabDestroy(tabID: tabUUID))))
    #expect(store.state.deeplinkInputConfirmation == nil)
    let hasDestroy = sent.value.contains(where: {
      if case .destroyTab = $0 { return true }
      return false
    })
    #expect(hasDestroy)
  }

  @Test(.dependencies) func surfaceDestroyShowsConfirmationWhenSettingDisabled() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let store = makeStore(worktree: worktree)

    await store.send(
      .deeplink(.worktree(id: worktree.id, action: .surfaceDestroy(tabID: tabUUID, surfaceID: surfaceUUID))))
    #expect(store.state.deeplinkInputConfirmation != nil)
  }

  @Test(.dependencies) func surfaceDestroySkipsConfirmationWhenSettingEnabled() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .always
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings,
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.surfaceExists = { _, _, _ in true }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(.worktree(id: worktree.id, action: .surfaceDestroy(tabID: tabUUID, surfaceID: surfaceUUID))))
    #expect(store.state.deeplinkInputConfirmation == nil)
    let hasDestroy = sent.value.contains(where: {
      if case .destroySurface = $0 { return true }
      return false
    })
    #expect(hasDestroy)
  }

  @Test(.dependencies) func surfaceWithInputShowsConfirmation() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let store = makeStore(worktree: worktree)

    await store.send(
      .deeplink(
        .worktree(
          id: worktree.id, action: .surface(tabID: tabUUID, surfaceID: surfaceUUID, input: "echo test"))))
    #expect(store.state.deeplinkInputConfirmation != nil)
    #expect(store.state.deeplinkInputConfirmation?.message == .command("echo test"))
  }

  @Test(.dependencies) func surfaceSplitWithInputShowsConfirmation() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let store = makeStore(worktree: worktree)

    await store.send(
      .deeplink(
        .worktree(
          id: worktree.id,
          action: .surfaceSplit(
            tabID: tabUUID, surfaceID: surfaceUUID, direction: .horizontal, input: "echo test", id: nil))))
    #expect(store.state.deeplinkInputConfirmation != nil)
    #expect(store.state.deeplinkInputConfirmation?.message == .command("echo test"))
  }

  @Test(.dependencies) func surfaceSplitWithoutInputSkipsConfirmation() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State(),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.surfaceExists = { _, _, _ in true }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(
          id: worktree.id,
          action: .surfaceSplit(
            tabID: tabUUID, surfaceID: surfaceUUID, direction: .vertical, input: nil, id: nil))))
    #expect(store.state.deeplinkInputConfirmation == nil)
    let hasSplit = sent.value.contains(where: {
      if case .splitSurface = $0 { return true }
      return false
    })
    #expect(hasSplit)
  }

  @Test(.dependencies) func surfaceSplitWithInputConfirmationAcceptedSendsCommand() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.deeplinkInputConfirmation = DeeplinkInputConfirmationFeature.State(
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      repositoryName: "repo",
      message: .command("echo test"),
      action: .surfaceSplit(
        tabID: tabUUID, surfaceID: surfaceUUID, direction: .horizontal, input: "echo test", id: nil),
    )
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.surfaceExists = { _, _, _ in true }
    }
    store.exhaustivity = .off

    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(
        .deeplinkInputConfirmation(
          .presented(
            .delegate(
              .confirm(
                worktreeID: worktree.id,
                action: .surfaceSplit(
                  tabID: tabUUID, surfaceID: surfaceUUID, direction: .horizontal,
                  input: "echo test", id: nil),
                alwaysAllow: false)))
        )
      ) {
        $0.deeplinkInputConfirmation = nil
      }
    }
    let hasSplit = sent.value.contains(where: {
      if case .splitSurface = $0 { return true }
      return false
    })
    #expect(hasSplit)
  }

  @Test(.dependencies) func settingsDeeplinkOpensGeneral() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.settings(section: nil)))
    await store.receive(\.settings.setSelection)
  }

  @Test(.dependencies) func settingsDeeplinkOpensSpecificSection() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.settings(section: .worktrees)))
    await store.receive(\.settings.setSelection)
  }

  @Test(.dependencies) func settingsRepoDeeplinkOpensRepoSettings() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.settingsRepo(repositoryID: "/tmp/repo")))
    await store.receive(\.settings.setSelection)
  }

  @Test(.dependencies) func settingsRepoDeeplinkWithUnknownRepoShowsAlert() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.settingsRepo(repositoryID: "/nonexistent")))
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func repoOpenDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.repoOpen(path: URL(fileURLWithPath: "/tmp/new-repo"))))
    await store.receive(\.repositories.openRepositories)
  }

  @Test(.dependencies) func repoWorktreeNewWithoutBranchDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(
      .deeplink(
        .repoWorktreeNew(
          repositoryID: "/tmp/repo",
          branch: nil,
          baseRef: nil,
          fetchOrigin: false
        )
      )
    )
    await store.receive(\.repositories.createRandomWorktreeInRepository)
  }

  // MARK: - Trailing slash normalization.

  @Test(.dependencies) func worktreeIDWithoutTrailingSlashMatchesWorktreeWithSlash() async {
    // Worktree IDs from standardizedFileURL have a trailing slash.
    let worktree = makeWorktree(id: "/tmp/repo/wt-1/")
    let store = makeStore(worktree: worktree)

    // Deeplink uses ID without trailing slash.
    await store.send(.deeplink(.worktree(id: "/tmp/repo/wt-1", action: .select)))
    await store.receive(\.repositories.selectWorktree)
  }

  // MARK: - Unknown worktree alert.

  @Test(.dependencies) func unknownWorktreeShowsAlert() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: "/nonexistent", action: .select)))
    #expect(store.state.alert != nil)
  }

  // MARK: - Tab actions.

  @Test(.dependencies) func worktreeTabWithValidTabID() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
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
      $0.terminalClient.tabExists = { _, _ in true }
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .tab(tabID: tabUUID))))
    await store.receive(\.repositories.selectWorktree)
    let expected = TerminalClient.Command.selectTab(worktree, tabID: TerminalTabID(rawValue: tabUUID))
    #expect(sent.value.contains(expected))
  }

  // MARK: - Tab new with input confirmation.

  @Test(.dependencies) func tabNewWithInputShowsConfirmationSheet() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .tabNew(input: "echo hello", id: nil))))
    #expect(store.state.deeplinkInputConfirmation != nil)
    #expect(store.state.deeplinkInputConfirmation?.message == .command("echo hello"))
    #expect(store.state.deeplinkInputConfirmation?.worktreeID == worktree.id)
  }

  @Test(.dependencies) func tabNewWithInputSkipsConfirmationWhenSettingEnabled() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .always
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings,
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .tabNew(input: "echo hello", id: nil))))
    #expect(store.state.deeplinkInputConfirmation == nil)
    #expect(
      sent.value.contains(
        .createTabWithInput(worktree, input: "echo hello", runSetupScriptIfNew: false, id: nil)
      )
    )
  }

  @Test(.dependencies) func tabNewConfirmationAcceptedSendsTerminalCommand() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.deeplinkInputConfirmation = makeConfirmationState(worktree: worktree, input: "echo hello")
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(
        .deeplinkInputConfirmation(
          .presented(
            .delegate(
              .confirm(worktreeID: worktree.id, action: .tabNew(input: "echo hello", id: nil), alwaysAllow: false)))
        )
      ) {
        $0.deeplinkInputConfirmation = nil
      }
    }
    #expect(
      sent.value.contains(
        .createTabWithInput(worktree, input: "echo hello", runSetupScriptIfNew: false, id: nil)
      )
    )
    await store.finish()
  }

  @Test(.dependencies) func tabNewConfirmationWithAlwaysAllowPersistsSetting() async {
    let worktree = makeWorktree()
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.deeplinkInputConfirmation = makeConfirmationState(worktree: worktree, input: "echo hello")
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(
        .deeplinkInputConfirmation(
          .presented(
            .delegate(
              .confirm(worktreeID: worktree.id, action: .tabNew(input: "echo hello", id: nil), alwaysAllow: true)))
        )
      ) {
        $0.deeplinkInputConfirmation = nil
      }
    }
    // The setting is persisted via SettingsFeature, not mutated directly.
    await store.receive(\.settings.setAutomatedActionPolicy) {
      $0.settings.automatedActionPolicy = .always
    }
    await store.finish()
  }

  @Test(.dependencies) func tabNewConfirmationCancelledDoesNothing() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.deeplinkInputConfirmation = makeConfirmationState(worktree: worktree, input: "echo hello")
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(.deeplinkInputConfirmation(.presented(.delegate(.cancel)))) {
        $0.deeplinkInputConfirmation = nil
      }
    }
    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func tabNewConfirmationWithDeletedWorktreeDoesNothing() async {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(
      repositories: RepositoriesFeature.State(),
      settings: SettingsFeature.State(),
    )
    initialState.deeplinkInputConfirmation = makeConfirmationState(
      worktreeID: "/nonexistent",
      worktreeName: "unknown",
      repositoryName: nil,
      input: "echo hello",
    )
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(
        .deeplinkInputConfirmation(
          .presented(
            .delegate(
              .confirm(
                worktreeID: "/nonexistent", action: .tabNew(input: "echo hello", id: nil), alwaysAllow: false)))
        )
      ) {
        $0.deeplinkInputConfirmation = nil
      }
    }
    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func tabNewWithoutInputCreatesNewTerminal() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State(),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .tabNew(input: nil, id: nil))))
    let hasCreateTab = sent.value.contains(where: {
      if case .createTab(let target, _, _) = $0 { return target.id == worktree.id }
      return false
    })
    #expect(hasCreateTab)
  }

  // MARK: - Queuing before load.

  @Test(.dependencies) func deeplinkQueuedBeforeLoadAndFlushedAfter() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktree: worktree)
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [repository]
    repositories.selection = .worktree(worktree.id)
    repositories.isInitialLoadComplete = false
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      let worktreeID = worktree.id
      $0[DeeplinkClient.self].parse = { _ in .worktree(id: worktreeID, action: .select) }
    }
    store.exhaustivity = .off

    await store.send(.deeplinkReceived(URL(string: "supacode://worktree/x")!)) {
      $0.pendingDeeplinks = [.worktree(id: worktree.id, action: .select)]
    }

    let repos = IdentifiedArray(uniqueElements: [repository])
    await store.send(.repositories(.delegate(.repositoriesChanged(repos)))) {
      $0.pendingDeeplinks = []
    }
    await store.receive(\.deeplink)
    await store.receive(\.repositories.selectWorktree)
  }

  @Test(.dependencies) func multipleDeeplinksQueuedBeforeLoadAllFlushed() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktree: worktree)
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [repository]
    repositories.selection = .worktree(worktree.id)
    repositories.isInitialLoadComplete = false
    let callCount = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      let worktreeID = worktree.id
      $0[DeeplinkClient.self].parse = { _ in
        let current = callCount.withValue { value -> Int in
          value += 1
          return value
        }
        return current == 1
          ? .worktree(id: worktreeID, action: .pin)
          : .worktree(id: worktreeID, action: .select)
      }
    }
    store.exhaustivity = .off

    // First deeplink queued.
    await store.send(.deeplinkReceived(URL(string: "supacode://first")!)) {
      $0.pendingDeeplinks = [.worktree(id: worktree.id, action: .pin)]
    }
    // Second deeplink appended.
    await store.send(.deeplinkReceived(URL(string: "supacode://second")!)) {
      $0.pendingDeeplinks = [
        .worktree(id: worktree.id, action: .pin),
        .worktree(id: worktree.id, action: .select),
      ]
    }

    let repos = IdentifiedArray(uniqueElements: [repository])
    await store.send(.repositories(.delegate(.repositoriesChanged(repos)))) {
      $0.pendingDeeplinks = []
    }
    // Both deeplinks should be dispatched (pin from first, select from second).
    await store.receive(\.deeplink)
    await store.receive(\.deeplink)
    await store.receive(\.repositories.pinWorktree)
    await store.receive(\.repositories.selectWorktree)
  }

  // MARK: - URL parsing integration.

  @Test(.dependencies) func deeplinkReceivedParsesAndDispatches() async {
    let worktree = makeWorktree()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0[DeeplinkClient.self] = .liveValue
    }
    store.exhaustivity = .off

    let encoded = worktree.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    let url = URL(string: "supacode://worktree/\(encoded)")!
    await store.send(.deeplinkReceived(url))
    await store.receive(\.deeplink)
    await store.receive(\.repositories.selectWorktree)
  }

  @Test(.dependencies) func deeplinkReceivedWithUnknownURLShowsAlert() async {
    let worktree = makeWorktree()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0[DeeplinkClient.self] = .liveValue
    }
    store.exhaustivity = .off

    await store.send(.deeplinkReceived(URL(string: "https://example.com")!))
    // Non-supacode scheme is silently ignored (debug log only, no alert).
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func deeplinkReceivedWithUnrecognizedHostShowsAlert() async {
    let worktree = makeWorktree()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0[DeeplinkClient.self] = .liveValue
    }
    store.exhaustivity = .off

    await store.send(.deeplinkReceived(URL(string: "supacode://unknown-host")!))
    #expect(store.state.alert != nil)
  }

  // MARK: - repositoriesLoaded flush.

  @Test(.dependencies) func deeplinkQueuedBeforeLoadAndFlushedOnRepositoriesLoaded() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktree: worktree)
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [repository]
    repositories.selection = .worktree(worktree.id)
    repositories.isInitialLoadComplete = false
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      let worktreeID = worktree.id
      $0[DeeplinkClient.self].parse = { _ in .worktree(id: worktreeID, action: .select) }
    }
    store.exhaustivity = .off

    await store.send(.deeplinkReceived(URL(string: "supacode://worktree/x")!)) {
      $0.pendingDeeplinks = [.worktree(id: worktree.id, action: .select)]
    }

    // Flush via repositoriesLoaded instead of repositoriesChanged delegate.
    await store.send(.repositories(.repositoriesLoaded([repository], failures: [], roots: [], animated: false))) {
      $0.pendingDeeplinks = []
    }
    await store.receive(\.deeplink)
    await store.receive(\.repositories.selectWorktree)
  }

  // MARK: - openRepositoriesFinished flush.

  @Test(.dependencies) func deeplinkQueuedBeforeLoadAndFlushedOnOpenRepositoriesFinished() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktree: worktree)
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [repository]
    repositories.selection = .worktree(worktree.id)
    repositories.isInitialLoadComplete = false
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      let worktreeID = worktree.id
      $0[DeeplinkClient.self].parse = { _ in .worktree(id: worktreeID, action: .select) }
    }
    store.exhaustivity = .off

    await store.send(.deeplinkReceived(URL(string: "supacode://worktree/x")!)) {
      $0.pendingDeeplinks = [.worktree(id: worktree.id, action: .select)]
    }

    // Flush via openRepositoriesFinished instead of repositoriesLoaded or repositoriesChanged.
    await store.send(
      .repositories(.openRepositoriesFinished([repository], failures: [], invalidRoots: [], roots: []))
    ) {
      $0.pendingDeeplinks = []
    }
    await store.receive(\.deeplink)
    await store.receive(\.repositories.selectWorktree)
  }

  // MARK: - repoWorktreeNew with branch through store.

  @Test(.dependencies) func repoWorktreeNewWithBranchDeeplink() async {
    let worktree = makeWorktree()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .repoWorktreeNew(
          repositoryID: "/tmp/repo",
          branch: "feature-x",
          baseRef: "main",
          fetchOrigin: true
        )
      )
    )
    await store.receive(\.repositories.createWorktreeInRepository)
    await store.finish()
  }

  @Test(.dependencies) func repoWorktreeNewWithUnknownRepoShowsAlert() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(
      .deeplink(.repoWorktreeNew(repositoryID: "/nonexistent", branch: nil, baseRef: nil, fetchOrigin: false)))
    #expect(store.state.alert != nil)
  }

  // MARK: - Surface focus without input.

  @Test(.dependencies) func surfaceFocusWithoutInputSendsTerminalCommand() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
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
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.surfaceExists = { _, _, _ in true }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .surface(tabID: tabUUID, surfaceID: surfaceUUID, input: nil))))
    #expect(store.state.deeplinkInputConfirmation == nil)
    let hasFocus = sent.value.contains(where: {
      if case .focusSurface = $0 { return true }
      return false
    })
    #expect(hasFocus)
  }

  // MARK: - Tab/surface not found alerts.

  @Test(.dependencies) func tabNotFoundShowsAlert() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, _ in false }
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .tab(tabID: tabUUID))))
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func surfaceNotFoundShowsAlert() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.surfaceExists = { _, _, _ in false }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .surface(tabID: tabUUID, surfaceID: surfaceUUID, input: nil))))
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func surfaceWithInputValidatesBeforeConfirmation() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.surfaceExists = { _, _, _ in false }
    }
    store.exhaustivity = .off

    // Surface doesn't exist — should show "not found" alert, not input confirmation.
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .surface(tabID: tabUUID, surfaceID: surfaceUUID, input: "echo test"))))
    #expect(store.state.alert != nil)
    #expect(store.state.deeplinkInputConfirmation == nil)
  }

  // MARK: - Socket source with responseFD.

  @Test(.dependencies) func socketDeeplinkSuccessSendsOkResponse() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    await store.send(.deeplink(.worktree(id: worktree.id, action: .select), source: .socket, responseFD: writeFD))
    await store.receive(\.repositories.selectWorktree)
    // Drain the response effect.
    await store.finish()

    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == true)
  }

  @Test(.dependencies) func socketDeeplinkUnknownWorktreeSendsErrorResponse() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    await store.send(.deeplink(.worktree(id: "/nonexistent", action: .select), source: .socket, responseFD: writeFD))
    await store.finish()

    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == false)
    #expect((response?["error"] as? String)?.isEmpty == false)
  }

  @Test(.dependencies) func socketDeeplinkBeforeLoadSendsStillLoadingError() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktree: worktree)
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [repository]
    repositories.isInitialLoadComplete = false
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      let worktreeID = worktree.id
      $0[DeeplinkClient.self].parse = { _ in .worktree(id: worktreeID, action: .select) }
    }
    store.exhaustivity = .off
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    await store.send(.deeplinkReceived(URL(string: "supacode://worktree/x")!, source: .socket, responseFD: writeFD))
    await store.finish()

    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == false)
    #expect((response?["error"] as? String)?.contains("loading") == true)
  }

  @Test(.dependencies) func socketDeeplinkConfirmationStoresFD() async {
    let worktree = makeWorktree()
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .never
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings,
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: "echo test", id: nil)),
        source: .socket,
        responseFD: 42
      )
    )
    #expect(store.state.deeplinkInputConfirmation?.responseFD == 42)
  }

  @Test(.dependencies) func socketDeeplinkSupersededConfirmationClosesOldFD() async {
    let worktree = makeWorktree()
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .never
    let (oldReadFD, oldWriteFD) = makePipe()
    defer { close(oldReadFD) }
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings,
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    // First command opens a confirmation dialog with the old FD.
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: "echo first", id: nil)),
        source: .socket,
        responseFD: oldWriteFD
      )
    )
    #expect(store.state.deeplinkInputConfirmation?.responseFD == oldWriteFD)

    // Second command supersedes — old FD should receive an error.
    let (newReadFD, newWriteFD) = makePipe()
    defer {
      close(newReadFD)
      close(newWriteFD)
    }
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: "echo second", id: nil)),
        source: .socket,
        responseFD: newWriteFD
      )
    )
    await store.finish()

    // The old FD should have been closed with a superseded error.
    let oldResponse = readPipeJSON(oldReadFD)
    #expect(oldResponse?["ok"] as? Bool == false)
    #expect((oldResponse?["error"] as? String)?.contains("Superseded") == true)

    // The new FD is stored in the confirmation.
    #expect(store.state.deeplinkInputConfirmation?.responseFD == newWriteFD)
  }

  @Test(.dependencies) func socketDeeplinkCancelSendsErrorResponse() async {
    let worktree = makeWorktree()
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.deeplinkInputConfirmation = DeeplinkInputConfirmationFeature.State(
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      repositoryName: "repo",
      message: .command("echo hello"),
      action: .tabNew(input: "echo hello", id: nil),
      responseFD: writeFD,
    )
    let store = TestStore(initialState: initialState) {
      AppFeature()
    }
    store.exhaustivity = .off

    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(.deeplinkInputConfirmation(.presented(.delegate(.cancel)))) {
        $0.deeplinkInputConfirmation = nil
      }
    }
    await store.finish()

    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == false)
    #expect(response?["error"] as? String == "Cancelled by user.")
  }

  @Test(.dependencies) func socketDeeplinkConfirmSendsOkResponse() async {
    let worktree = makeWorktree()
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.deeplinkInputConfirmation = DeeplinkInputConfirmationFeature.State(
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      repositoryName: "repo",
      message: .command("echo hello"),
      action: .tabNew(input: "echo hello", id: nil),
      responseFD: writeFD,
    )
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(
        .deeplinkInputConfirmation(
          .presented(
            .delegate(
              .confirm(worktreeID: worktree.id, action: .tabNew(input: "echo hello", id: nil), alwaysAllow: false)))
        )
      ) {
        $0.deeplinkInputConfirmation = nil
      }
    }
    await store.finish()

    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == true)
  }

  @Test(.dependencies) func cliOnlyPolicyBypassesConfirmationForSocket() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .cliOnly
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings,
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: "echo test", id: nil)),
        source: .socket
      )
    )
    #expect(store.state.deeplinkInputConfirmation == nil)
    #expect(
      sent.value.contains(
        .createTabWithInput(worktree, input: "echo test", runSetupScriptIfNew: false, id: nil)
      )
    )
  }

  @Test(.dependencies) func cliOnlyPolicyRequiresConfirmationForURLScheme() async {
    let worktree = makeWorktree()
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .cliOnly
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings,
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: "echo test", id: nil)),
        source: .urlScheme
      )
    )
    #expect(store.state.deeplinkInputConfirmation != nil)
  }

  // MARK: - Helpers.

  private func makeWorktree(
    id: String = "/tmp/repo/wt-1",
    name: String = "wt-1"
  ) -> Worktree {
    Worktree(
      id: id,
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
  }

  private func makeRepository(worktree: Worktree) -> Repository {
    Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: [worktree],
    )
  }

  private func makeRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    let repository = makeRepository(worktree: worktree)
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    repositoriesState.isInitialLoadComplete = true
    return repositoriesState
  }

  private func makeStore(worktree: Worktree) -> TestStoreOf<AppFeature> {
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.surfaceExists = { _, _, _ in true }
    }
    store.exhaustivity = .off
    return store
  }

  private func makeConfirmationState(
    worktree: Worktree,
    input: String
  ) -> DeeplinkInputConfirmationFeature.State {
    makeConfirmationState(
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      repositoryName: "repo",
      input: input,
    )
  }

  private func makeConfirmationState(
    worktreeID: Worktree.ID,
    worktreeName: String,
    repositoryName: String?,
    input: String
  ) -> DeeplinkInputConfirmationFeature.State {
    DeeplinkInputConfirmationFeature.State(
      worktreeID: worktreeID,
      worktreeName: worktreeName,
      repositoryName: repositoryName,
      message: .command(input),
      action: .tabNew(input: input, id: nil),
    )
  }

  // MARK: - Quit drains pending responseFD.

  @Test(.dependencies) func dialogDismissDrainsPendingResponseFD() async {
    let worktree = makeWorktree()
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.deeplinkInputConfirmation = DeeplinkInputConfirmationFeature.State(
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      repositoryName: "repo",
      message: .command("echo hello"),
      action: .tabNew(input: "echo hello", id: nil),
      responseFD: writeFD,
    )
    let store = TestStore(initialState: initialState) {
      AppFeature()
    }
    store.exhaustivity = .off

    // Test via .dismiss rather than .requestQuit to avoid NSApplication.terminate
    // killing the test runner in DEBUG builds.
    await store.send(.deeplinkInputConfirmation(.dismiss))
    await store.finish()

    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == false)
  }

  // MARK: - deeplinksOnly policy.

  @Test(.dependencies) func deeplinksOnlyPolicyBypassesConfirmationForURLScheme() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .deeplinksOnly
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings,
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: "echo test", id: nil)),
        source: .urlScheme
      )
    )
    #expect(store.state.deeplinkInputConfirmation == nil)
    #expect(
      sent.value.contains(
        .createTabWithInput(worktree, input: "echo test", runSetupScriptIfNew: false, id: nil)
      )
    )
  }

  @Test(.dependencies) func deeplinksOnlyPolicyRequiresConfirmationForSocket() async {
    let worktree = makeWorktree()
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .deeplinksOnly
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings,
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: "echo test", id: nil)),
        source: .socket
      )
    )
    #expect(store.state.deeplinkInputConfirmation != nil)
  }

  // MARK: - Invalid socket deeplink sends FD error response.

  @Test(.dependencies) func socketDeeplinkWithInvalidURLSendsErrorResponse() async {
    let worktree = makeWorktree()
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0[DeeplinkClient.self].parse = { _ in nil }
    }
    store.exhaustivity = .off

    await store.send(.deeplinkReceived(URL(string: "supacode://bad")!, source: .socket, responseFD: writeFD))
    await store.finish()

    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == false)
    #expect((response?["error"] as? String)?.contains("Invalid deeplink") == true)
  }

  // MARK: - Duplicate ID rejection.

  @Test(.dependencies) func tabNewWithDuplicateExplicitIDShowsAlert() async {
    let worktree = makeWorktree()
    let existingTabID = UUID()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State(),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, tabID in tabID.rawValue == existingTabID }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(.worktree(id: worktree.id, action: .tabNew(input: nil, id: existingTabID))))
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func surfaceSplitWithDuplicateExplicitIDShowsAlert() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let existingSurfaceID = UUID()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State(),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.surfaceExists = { _, _, _ in true }
      $0.terminalClient.surfaceExistsInWorktree = { _, sID in sID == existingSurfaceID }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(
          id: worktree.id,
          action: .surfaceSplit(
            tabID: tabUUID, surfaceID: surfaceUUID, direction: .horizontal,
            input: nil, id: existingSurfaceID))))
    #expect(store.state.alert != nil)
    #expect(store.state.deeplinkInputConfirmation == nil)
  }

  // MARK: - Pipe helpers for responseFD testing.

  private func makePipe() -> (readFD: Int32, writeFD: Int32) {
    var fds: [Int32] = [0, 0]
    let result = fds.withUnsafeMutableBufferPointer { buf in
      Darwin.pipe(buf.baseAddress!)
    }
    precondition(result == 0, "pipe() failed")
    return (fds[0], fds[1])
  }

  private func readPipeJSON(_ fileDescriptor: Int32) -> [String: Any]? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let bytesRead = buffer.withUnsafeMutableBufferPointer { buf in
        Darwin.read(fileDescriptor, buf.baseAddress!, buf.count)
      }
      guard bytesRead > 0 else { break }
      data.append(contentsOf: buffer.prefix(bytesRead))
    }
    guard !data.isEmpty else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
}
