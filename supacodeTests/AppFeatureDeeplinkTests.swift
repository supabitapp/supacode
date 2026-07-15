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
struct AppFeatureDeeplinkTests {
  // MARK: - Routing after load.

  @Test(.dependencies) func selectWorktreeDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .select)))
    await store.receive(\.repositories.selectWorktree)
  }

  @Test(.dependencies) func runDeeplinkOnMissingWorktreeSurfacesAlertAndBlocksSpawn() async {
    let worktree = Worktree(
      id: "/tmp/repo/gone",
      name: "gone",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/gone"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
      isMissing: true
    )
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .run))) {
      $0.repositories.alert = nil
      $0.alert = AlertState {
        TextState("Working directory missing")
      } actions: {
        ButtonState(role: .cancel, action: .dismiss) {
          TextState("OK")
        }
      } message: {
        TextState(
          "\(worktree.name) has no working directory on disk. Restore it or delete the worktree."
        )
      }
    }
    await store.receive(\.repositories.selectWorktree)
  }

  // Cleanup actions (here: .pin) stay reachable on orphans so the user can
  // dismiss the row; verifying one non-spawning case pins the spawnsShell matrix.
  @Test(.dependencies) func pinDeeplinkOnMissingWorktreeRoutedWithoutOrphanAlert() async {
    let worktree = Worktree(
      id: "/tmp/repo/gone",
      name: "gone",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/gone"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
      isMissing: true
    )
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .pin)))
    await store.receive(\.repositories.selectWorktree)
    await store.receive(\.repositories.pinWorktree)
    #expect(store.state.alert == nil)
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

  @Test(.dependencies) func appearanceWorktreeDeeplinkSetsTitleAndColor() async {
    let worktree = makeWorktree()
    let (store, repositoryID) = makeStoreWithSidebarItem(worktree: worktree, item: .init())

    await store.send(.deeplink(.worktree(id: worktree.id, action: .appearance(title: "Custom", color: "red"))))
    await store.receive(\.repositories.setWorktreeAppearance)

    let item = store.state.repositories.sidebar
      .sections[repositoryID]?.buckets[.pinned]?.items[worktree.id]
    #expect(item?.title == "Custom")
    #expect(item?.color == .red)
  }

  @Test(.dependencies) func appearanceWorktreeDeeplinkColorOnlyPreservesTitleOverride() async {
    let worktree = makeWorktree()
    let (store, repositoryID) = makeStoreWithSidebarItem(
      worktree: worktree,
      item: .init(title: "Custom")
    )

    await store.send(.deeplink(.worktree(id: worktree.id, action: .appearance(title: nil, color: "#A1B2C3"))))
    await store.receive(\.repositories.setWorktreeAppearance)

    let item = store.state.repositories.sidebar
      .sections[repositoryID]?.buckets[.pinned]?.items[worktree.id]
    #expect(item?.title == "Custom")
    #expect(item?.color == .custom("#A1B2C3"))
  }

  @Test(.dependencies) func appearanceWorktreeDeeplinkTitleOnlyPreservesColor() async {
    let worktree = makeWorktree()
    let (store, repositoryID) = makeStoreWithSidebarItem(
      worktree: worktree,
      item: .init(title: "Old", color: .blue)
    )

    await store.send(.deeplink(.worktree(id: worktree.id, action: .appearance(title: "New", color: nil))))
    await store.receive(\.repositories.setWorktreeAppearance)

    let item = store.state.repositories.sidebar
      .sections[repositoryID]?.buckets[.pinned]?.items[worktree.id]
    #expect(item?.title == "New")
    #expect(item?.color == .blue)
  }

  @Test(.dependencies) func appearanceWorktreeDeeplinkClearsTitleAndColor() async {
    let worktree = makeWorktree()
    let (store, repositoryID) = makeStoreWithSidebarItem(
      worktree: worktree,
      item: .init(title: "Custom", color: .blue)
    )

    await store.send(.deeplink(.worktree(id: worktree.id, action: .appearance(title: "", color: "none"))))
    await store.receive(\.repositories.setWorktreeAppearance)

    let item = store.state.repositories.sidebar
      .sections[repositoryID]?.buckets[.pinned]?.items[worktree.id]
    #expect(item?.title == nil)
    #expect(item?.color == nil)
  }

  @Test(.dependencies) func appearanceWorktreeDeeplinkWithInvalidColorShowsAlert() async {
    let worktree = makeWorktree()
    let (store, repositoryID) = makeStoreWithSidebarItem(
      worktree: worktree,
      item: .init(title: "Custom", color: .blue)
    )

    await store.send(.deeplink(.worktree(id: worktree.id, action: .appearance(title: nil, color: "mauve"))))
    await store.finish()

    // The alert doubles as the socket-ack failure signal, so a CLI caller
    // gets ok=false instead of a silent success. Appearance never selects the
    // worktree, so no `selectWorktree` is received.
    #expect(store.state.alert != nil)
    let item = store.state.repositories.sidebar
      .sections[repositoryID]?.buckets[.pinned]?.items[worktree.id]
    #expect(item?.color == .blue)
    #expect(item?.title == "Custom")
  }

  @Test(.dependencies) func appearanceWorktreeDeeplinkWithInvalidColorStillAppliesTitle() async {
    let worktree = makeWorktree()
    let (store, repositoryID) = makeStoreWithSidebarItem(
      worktree: worktree,
      item: .init(title: "Custom", color: .blue)
    )

    await store.send(.deeplink(.worktree(id: worktree.id, action: .appearance(title: "New", color: ""))))
    await store.receive(\.repositories.setWorktreeAppearance)
    await store.finish()

    // An invalid color no longer rejects a valid title: the title applies, the
    // tint is left unchanged, and the alert still signals ok=false.
    #expect(store.state.alert != nil)
    let item = store.state.repositories.sidebar
      .sections[repositoryID]?.buckets[.pinned]?.items[worktree.id]
    #expect(item?.color == .blue)
    #expect(item?.title == "New")
  }

  @Test(.dependencies) func appearanceWorktreeDeeplinkWhitespaceOnlyTitleClearsOverride() async {
    let worktree = makeWorktree()
    let (store, repositoryID) = makeStoreWithSidebarItem(
      worktree: worktree,
      item: .init(title: "Custom", color: .blue)
    )

    await store.send(.deeplink(.worktree(id: worktree.id, action: .appearance(title: "   ", color: nil))))
    await store.receive(\.repositories.setWorktreeAppearance)

    let item = store.state.repositories.sidebar
      .sections[repositoryID]?.buckets[.pinned]?.items[worktree.id]
    #expect(item?.title == nil)
    #expect(item?.color == .blue)
  }

  @Test(.dependencies) func appearanceWorktreeDeeplinkCollapsesControlCharactersInTitle() async {
    let worktree = makeWorktree()
    let (store, repositoryID) = makeStoreWithSidebarItem(worktree: worktree, item: .init())

    await store.send(.deeplink(.worktree(id: worktree.id, action: .appearance(title: "a\tb\nc", color: nil))))
    await store.receive(\.repositories.setWorktreeAppearance)

    let item = store.state.repositories.sidebar
      .sections[repositoryID]?.buckets[.pinned]?.items[worktree.id]
    #expect(item?.title == "a b c")
  }

  @Test(.dependencies) func archiveWorktreeDeeplinkShowsConfirmation() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    // Default policy `.cliOnly` does not bypass a URL-scheme deeplink, so it prompts.
    await store.send(.deeplink(.worktree(id: worktree.id, action: .archive)))
    #expect(store.state.deeplinkInputConfirmation?.message == .confirmation("Archive worktree \"wt-1\"?"))
    #expect(store.state.deeplinkInputConfirmation?.action == .archive)
  }

  @Test(.dependencies) func archiveWorktreeDeeplinkSkipsConfirmationWhenPolicyAllows() async {
    let worktree = makeWorktree()
    clearArchiveScript(for: worktree)
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
      $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .archive)))
    #expect(store.state.deeplinkInputConfirmation == nil)
    await store.receive(\.repositories.archiveWorktreeConfirmed)
  }

  @Test(.dependencies) func archiveWorktreeSocketDeeplinkSkipsConfirmationUnderCLIOnly() async {
    let worktree = makeWorktree()
    clearArchiveScript(for: worktree)
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State(),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
    }
    store.exhaustivity = .off

    // `.cliOnly` (the default) bypasses for a socket command.
    await store.send(
      .deeplink(.worktree(id: worktree.id, action: .archive), source: .socket))
    #expect(store.state.deeplinkInputConfirmation == nil)
    await store.receive(\.repositories.archiveWorktreeConfirmed)
  }

  @Test(.dependencies) func archiveWorktreeMergedDeeplinkSkipsConfirmation() async {
    let worktree = makeWorktree()
    clearArchiveScript(for: worktree)
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .never
    var repositories = makeRepositoriesState(worktree: worktree)
    repositories.reconcileSidebarForTesting()
    repositories.setWorktreeInfoForTesting(id: worktree.id, pullRequest: makeMergedPullRequest())
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositories, settings: settings)
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
    }
    store.exhaustivity = .off

    // Merged worktrees never prompt, even when the policy would otherwise require it.
    await store.send(.deeplink(.worktree(id: worktree.id, action: .archive)))
    #expect(store.state.deeplinkInputConfirmation == nil)
    await store.receive(\.repositories.archiveWorktreeConfirmed)
  }

  @Test(.dependencies) func archiveMainWorktreeDeeplinkRejected() async {
    let main = makeWorktree(id: "/tmp/repo", name: "main")
    let store = makeStore(worktree: main)

    await store.send(.deeplink(.worktree(id: main.id, action: .archive), source: .socket))
    #expect(store.state.alert != nil)
    #expect(store.state.deeplinkInputConfirmation == nil)
    #expect(store.state.pendingCommandAcks.isEmpty)
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
      kind: .folder,
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: RepositoryID(folderRoot),
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
    repositories.reconcileSidebarForTesting()
    repositories.sidebarItems[id: worktree.id]?.runningScripts[id: definition.id] =
      .init(id: definition.id, tint: definition.resolvedTintColor)
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

  @Test(.dependencies) func runScriptDeeplinkResolvesGlobalScript() async {
    let worktree = makeWorktree()
    let globalScript = ScriptDefinition(kind: .custom, name: "Lint", command: "make lint")
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.globalScripts = [globalScript] }
    defer { $settingsFile.withLock { $0.global.globalScripts = [] } }
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

    await store.send(.deeplink(.worktree(id: worktree.id, action: .runScript(scriptID: globalScript.id))))
    await store.finish()

    let hasRun = sent.value.contains(where: {
      if case .runBlockingScript(_, .script(let definition), _) = $0 {
        return definition.id == globalScript.id
      }
      return false
    })
    #expect(hasRun)
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func stopScriptDeeplinkResolvesGlobalScript() async {
    let worktree = makeWorktree()
    let globalScript = ScriptDefinition(kind: .custom, name: "Lint", command: "make lint")
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.globalScripts = [globalScript] }
    defer { $settingsFile.withLock { $0.global.globalScripts = [] } }
    var repositories = makeRepositoriesState(worktree: worktree)
    repositories.reconcileSidebarForTesting()
    repositories.sidebarItems[id: worktree.id]?.runningScripts[id: globalScript.id] =
      .init(id: globalScript.id, tint: globalScript.resolvedTintColor)
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

    await store.send(.deeplink(.worktree(id: worktree.id, action: .stopScript(scriptID: globalScript.id))))
    await store.finish()

    let hasStop = sent.value.contains(where: {
      if case .stopScript(_, let definitionID) = $0 { return definitionID == globalScript.id }
      return false
    })
    #expect(hasStop)
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func runScriptDeeplinkPrefersRepoOnIDCollision() async {
    let sharedID = UUID()
    let repoScript = ScriptDefinition(id: sharedID, kind: .test, name: "Repo", command: "echo repo")
    let globalScript = ScriptDefinition(id: sharedID, kind: .custom, name: "Global", command: "echo global")
    let worktree = makeWorktree()
    let rootURL = worktree.repositoryRootURL
    @Shared(.repositorySettings(rootURL)) var persisted = .default
    $persisted.withLock { $0.scripts = [repoScript] }
    defer { $persisted.withLock { $0.scripts = [] } }
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.globalScripts = [globalScript] }
    defer { $settingsFile.withLock { $0.global.globalScripts = [] } }
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

    await store.send(.deeplink(.worktree(id: worktree.id, action: .runScript(scriptID: sharedID))))
    await store.finish()

    let runCommands = sent.value.compactMap { command -> ScriptDefinition? in
      if case .runBlockingScript(_, .script(let def), _) = command { return def }
      return nil
    }
    #expect(runCommands.count == 1)
    #expect(runCommands.first?.command == "echo repo")
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
    repositories.reconcileSidebarForTesting()
    repositories.sidebarItems[id: worktree.id]?.runningScripts[id: definition.id] =
      .init(id: definition.id, tint: definition.resolvedTintColor)
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
        responseFD: 42,
        timeoutSeconds: 0
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

  @Test(.dependencies) func settingsDeeplinkOpensGlobalScriptsSection() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.settings(section: .scripts)))
    await store.receive(\.settings.setSelection) {
      $0.settings.selection = .scripts
    }
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

  @Test(.dependencies) func settingsRepoScriptsDeeplinkOpensScriptsPane() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.settingsRepoScripts(repositoryID: "/tmp/repo")))
    await store.receive(\.settings.setSelection)
  }

  @Test(.dependencies) func settingsRepoScriptsDeeplinkWithUnknownRepoShowsAlert() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.settingsRepoScripts(repositoryID: "/nonexistent")))
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func settingsRepoScriptsDeeplinkOpensScriptsPaneForFolderRepo() async {
    let folderRoot = "/tmp/folder-scripts-\(UUID().uuidString)"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      kind: .folder,
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: RepositoryID(folderRoot),
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

    await store.send(.deeplink(.settingsRepoScripts(repositoryID: RepositoryID(folderRoot))))
    await store.receive(\.settings.setSelection)
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
          fetchOrigin: false,
          worktreeName: nil,
          worktreePath: nil
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
      if case .createTab(let target, _, _, _) = $0 { return target.id == worktree.id }
      return false
    })
    #expect(hasCreateTab)
  }

  @Test(.dependencies) func tabNewWithTitleCreatesNamedTerminal() async {
    let worktree = makeWorktree()
    let tabID = UUID()
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
      $0.terminalClient.tabExists = { _, _ in false }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(
          id: worktree.id,
          action: .tabNew(input: nil, id: tabID, title: "implement")
        )
      )
    )
    #expect(
      sent.value.contains(
        .createTab(
          worktree,
          runSetupScriptIfNew: true,
          id: tabID,
          title: "implement"
        )
      )
    )
  }

  @Test(.dependencies) func tabNewWithInputPreservesTitleThroughConfirmation() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.deeplinkInputConfirmation = DeeplinkInputConfirmationFeature.State(
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      repositoryName: "repo",
      message: .command("omp"),
      action: .tabNew(input: "omp", id: nil, title: "implement"),
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
                worktreeID: worktree.id,
                action: .tabNew(input: "omp", id: nil, title: "implement"),
                alwaysAllow: false
              )
            )
          )
        )
      ) {
        $0.deeplinkInputConfirmation = nil
      }
    }
    #expect(
      sent.value.contains(
        .createTabWithInput(
          worktree,
          input: "omp",
          runSetupScriptIfNew: false,
          id: nil,
          title: "implement"
        )
      )
    )
    await store.finish()
  }

  @Test(.dependencies) func tabRenameUpdatesExistingTab() async {
    let worktree = makeWorktree()
    let tabID = UUID()
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
      $0.terminalClient.tabExists = { worktreeID, candidate in
        worktreeID == worktree.id && candidate.rawValue == tabID
      }
      $0.terminalClient.tabCanRename = { worktreeID, candidate in
        worktreeID == worktree.id && candidate.rawValue == tabID
      }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabRename(tabID: tabID, title: "review"))
      )
    )
    #expect(
      sent.value.contains(
        .renameTab(worktree, tabID: TerminalTabID(rawValue: tabID), title: "review")
      )
    )
  }

  @Test(.dependencies) func tabRenameWithEmptyTitleClearsOverride() async {
    let worktree = makeWorktree()
    let tabID = UUID()
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
      $0.terminalClient.tabCanRename = { _, _ in true }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabRename(tabID: tabID, title: ""))
      )
    )
    #expect(
      sent.value.contains(
        .renameTab(worktree, tabID: TerminalTabID(rawValue: tabID), title: "")
      )
    )
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func tabRenameWithControlOnlyTitleShowsAlertAndSendsNothing() async {
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
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.tabCanRename = { _, _ in true }
    }
    store.exhaustivity = .off

    // Only an escape: it is not a clear, and it must not wipe the existing title.
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabRename(tabID: UUID(), title: "\u{1B}"))
      )
    )
    #expect(store.state.alert?.title == TextState("Tab title is blank"))
    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func tabRenameDoesNotSelectWorktree() async {
    let worktree = makeWorktree()
    let tabID = UUID()
    var repositories = makeRepositoriesState(worktree: worktree)
    repositories.selection = nil
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State(),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.tabCanRename = { _, _ in true }
    }

    // Exhaustive: a `selectWorktree` would fail here, so renaming cannot steal focus.
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabRename(tabID: tabID, title: "review"))
      )
    )
    await store.finish()
    #expect(store.state.repositories.selection == nil)
  }

  @Test(.dependencies) func tabNewWithBlankTitleShowsAlertAndSendsNothing() async {
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
      $0.terminalClient.tabExists = { _, _ in false }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: nil, id: nil, title: "   "))
      )
    )
    #expect(store.state.alert?.title == TextState("Tab title is blank"))
    #expect(!sent.value.contains { if case .createTab = $0 { true } else { false } })
  }

  @Test(.dependencies) func tabRenameMissingTabShowsAlertAndSendsNothing() async {
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
      $0.terminalClient.tabExists = { _, _ in false }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabRename(tabID: UUID(), title: "review"))
      )
    )
    #expect(store.state.alert?.title == TextState("Tab not found"))
    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func tabRenameLockedTitleShowsAlertAndSendsNothing() async {
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
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.tabCanRename = { _, _ in false }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabRename(tabID: UUID(), title: "review"))
      )
    )
    #expect(store.state.alert?.title == TextState("Tab cannot be renamed"))
    #expect(sent.value.isEmpty)
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

    let encoded = worktree.id.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
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
          fetchOrigin: true,
          worktreeName: nil,
          worktreePath: nil
        )
      )
    )
    await store.receive(\.repositories.createWorktreeInRepository)
    await store.finish()
  }

  @Test(.dependencies) func repoWorktreeNewForwardsNameAndLocationToStream() async {
    let worktree = makeWorktree()
    let createdWorktree = makeWorktree()
    let observedDirectoryOverride = LockIsolated<URL?>(nil)
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isValidBranchName = { _, _ in true }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _, directoryOverride in
        observedDirectoryOverride.withValue { $0 = directoryOverride }
        return AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree] }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .repoWorktreeNew(
          repositoryID: "/tmp/repo",
          branch: "feature/foo",
          baseRef: "main",
          fetchOrigin: false,
          worktreeName: "feature_foo",
          worktreePath: "/tmp/elsewhere"
        )
      )
    )
    await store.finish()

    #expect(
      observedDirectoryOverride.value
        == URL(filePath: "/tmp/elsewhere/feature_foo", directoryHint: .isDirectory).standardizedFileURL)
  }

  @Test(.dependencies) func repoWorktreeNewWithUnknownRepoShowsAlert() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(
      .deeplink(
        .repoWorktreeNew(
          repositoryID: "/nonexistent",
          branch: nil,
          baseRef: nil,
          fetchOrigin: false,
          worktreeName: nil,
          worktreePath: nil
        )))
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
        responseFD: 42,
        timeoutSeconds: 0
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
        responseFD: oldWriteFD,
        timeoutSeconds: 0
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
        responseFD: newWriteFD,
        timeoutSeconds: 0
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
      id: WorktreeID(id),
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

  /// `@Shared(.repositorySettings)` is process-global and keyed by root URL, so a
  /// prior test can leave a non-empty archive script that would divert the archive
  /// into the blocking-script path. Reset it so the flow runs straight to apply.
  private func clearArchiveScript(for worktree: Worktree) {
    @Shared(.repositorySettings(worktree.repositoryRootURL, host: worktree.host)) var settings
    $settings.withLock { $0.archiveScript = "" }
  }

  private func makeMergedPullRequest() -> GithubPullRequest {
    GithubPullRequest(
      number: 1,
      title: "PR",
      state: "MERGED",
      additions: 0,
      deletions: 0,
      isDraft: false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      url: "https://example.com/pull/1",
      headRefName: nil,
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "khoi",
      statusCheckRollup: nil,
      mergeQueueEntry: nil
    )
  }

  /// Store whose sidebar has `worktree` seeded into the `.pinned` bucket with
  /// the given item payload, so appearance deeplink tests can assert title / color
  /// preservation end to end. Returns the owning repository ID for lookups.
  private func makeStoreWithSidebarItem(
    worktree: Worktree,
    item: SidebarState.Item
  ) -> (TestStoreOf<AppFeature>, Repository.ID) {
    var repositories = makeRepositoriesState(worktree: worktree)
    let repositoryID = makeRepository(worktree: worktree).id
    repositories.$sidebar.withLock { sidebar in
      sidebar.sections[repositoryID, default: .init()]
        .buckets[.pinned, default: .init()]
        .items[worktree.id] = item
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
    return (store, repositoryID)
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

  // MARK: - Quit.

  // `.requestQuit` always terminates immediately now that zmx persists surfaces across quit.
  // Tests MUST inject an `AppLifecycleClient.terminate` override; otherwise the live client
  // kills the test process via `NSApplication.shared.terminate(nil)`.

  @Test(.dependencies) func requestQuitTerminates() async {
    let worktree = makeWorktree()
    let terminated = LockIsolated(false)
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State(),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.appLifecycleClient.terminate = { terminated.setValue(true) }
      $0.terminalClient.hasInflightBlockingScripts = { false }
    }
    store.exhaustivity = .off

    await store.send(.requestQuit)
    await store.finish()

    #expect(terminated.value)
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func requestQuitWithAlwaysModeShowsAlert() async {
    let worktree = makeWorktree()
    var settings = GlobalSettings.default
    settings.confirmQuitMode = .always
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State(settings: settings),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.hasInflightBlockingScripts = { false }
    }
    store.exhaustivity = .off

    await store.send(.requestQuit)
    await store.finish()

    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func requestQuitInAutoModeWithBlockingScriptShowsAlert() async {
    let worktree = makeWorktree()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State(),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.hasInflightBlockingScripts = { true }
    }
    store.exhaustivity = .off

    await store.send(.requestQuit)
    await store.finish()

    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func confirmQuitAndTerminateInvokesTerminateAllSessions() async {
    let worktree = makeWorktree()
    let terminated = LockIsolated(false)
    let terminateSessionsCalled = LockIsolated(false)
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.alert = AlertState { TextState("Quit Supacode?") }
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.appLifecycleClient.terminate = { terminated.setValue(true) }
      $0.terminalClient.terminateAllSessions = { terminateSessionsCalled.setValue(true) }
    }
    store.exhaustivity = .off

    await store.send(.alert(.presented(.confirmQuitAndTerminate)))
    await store.finish()

    #expect(terminateSessionsCalled.value)
    #expect(terminated.value)
    #expect(store.state.alert == nil)
  }

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

    await store.send(.deeplinkInputConfirmation(.dismiss))
    await store.finish()

    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == false)
  }

  @Test(.dependencies) func cancelQuitAlertPreservesPendingResponseFD() async {
    // Regression guard for the deleted pre-three-button-alert test: dismissing
    // the quit confirmation must NOT drain a pending CLI socket response FD.
    // Only `confirmQuit` / `confirmQuitAndTerminate` should trigger the drain.
    let worktree = makeWorktree()
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }
    var settings = GlobalSettings.default
    settings.confirmQuitMode = .always
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(settings: settings),
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
      $0.terminalClient.hasInflightBlockingScripts = { false }
    }
    store.exhaustivity = .off

    await store.send(.requestQuit)
    #expect(store.state.alert != nil)
    let priorFD = store.state.deeplinkInputConfirmation?.responseFD
    await store.send(.alert(.dismiss))

    #expect(store.state.alert == nil)
    // Critical: the FD must still be live on the confirmation state, NOT drained.
    #expect(store.state.deeplinkInputConfirmation?.responseFD == priorFD)
    // No JSON should have been written by the dismiss; the FD stays open for
    // the eventual deeplink confirmation to drain.
    _ = writeFD
  }

  @Test(.dependencies) func requestQuitInNeverModeSkipsAlertEvenWithActiveWork() async {
    // `.never` short-circuits before `hasActiveWorkBlockingQuit` runs.
    let worktree = makeWorktree()
    let terminated = LockIsolated(false)
    var settings = GlobalSettings.default
    settings.confirmQuitMode = .never
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State(settings: settings),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.appLifecycleClient.terminate = { terminated.setValue(true) }
      // Active work, but `.never` shouldn't even consult it.
      $0.terminalClient.hasInflightBlockingScripts = { true }
    }
    store.exhaustivity = .off

    await store.send(.requestQuit)
    await store.finish()

    #expect(store.state.alert == nil)
    #expect(terminated.value)
  }

  @Test(.dependencies) func requestQuitInAutoModeWithBusyAgentShowsAlert() async {
    let worktree = makeWorktree()
    var repositoriesState = makeRepositoriesState(worktree: worktree)
    repositoriesState.reconcileSidebarForTesting()
    repositoriesState.sidebarItems[id: worktree.id]?.agentSnapshot.agents = [
      .init(agent: .claude, activity: .busy)
    ]
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State(),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.hasInflightBlockingScripts = { false }
    }
    store.exhaustivity = .off

    await store.send(.requestQuit)
    await store.finish()

    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func requestQuitInAutoModeWithPendingLifecycleShowsAlert() async {
    let worktree = makeWorktree()
    var repositoriesState = makeRepositoriesState(worktree: worktree)
    repositoriesState.reconcileSidebarForTesting()
    repositoriesState.sidebarItems[id: worktree.id]?.lifecycle = .pending
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State(),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.hasInflightBlockingScripts = { false }
    }
    store.exhaustivity = .off

    await store.send(.requestQuit)
    await store.finish()

    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func requestTerminateAllTerminalSessionsShowsAlertAndConfirmInvokesTerminate() async {
    let worktree = makeWorktree()
    let terminateCalled = LockIsolated(false)
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State(),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.terminateAllSessions = { terminateCalled.setValue(true) }
    }
    store.exhaustivity = .off

    await store.send(.requestTerminateAllTerminalSessions)
    #expect(store.state.alert != nil)

    await store.send(.alert(.presented(.confirmTerminateAllTerminalSessions)))
    await store.finish()

    #expect(terminateCalled.value)
    #expect(store.state.alert == nil)
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
