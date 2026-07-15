import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureDefaultEditorTests {
  @Test(.dependencies) func defaultEditorAppliesToAutomaticRepositorySettings() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(worktree: worktree)
    let storage = SettingsTestStorage()
    let settingsFileURL = URL(
      fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json"
    )
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
    } operation: {
      var settings = GlobalSettings.default
      settings.defaultEditorID = OpenWorktreeAction.finder.settingsID
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global = settings }
      return TestStore(
        initialState: AppFeature.State(
          repositories: repositoriesState,
          settings: SettingsFeature.State(settings: settings)
        )
      ) {
        AppFeature()
      }
    }

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree)))) {
      $0.repositories.$sidebar.withLock { sidebar in
        sidebar.focusedWorktreeID = worktree.id
      }
    }
    await store.receive(\.worktreeSettingsLoaded) {
      $0.loadedRepoScripts = LoadedRepositoryScripts(
        scripts: [],
        rootURL: worktree.repositoryRootURL,
        host: worktree.host
      )
    }

    // The repository sets no override, so it takes the global default editor. The seed
    // reads that from memory, and the pass confirms the file says nothing else.
    let repository = store.state.repositories.repositories[0]
    await store.send(.repositories(.resolveOpenActions)) {
      $0.repositories.openActionByRepositoryID = [repository.id: .finder]
    }
    await store.receive(\.repositories.openActionsResolved)
    #expect(store.state.openActionSelection == .finder)
    #expect(store.state.repoScripts.isEmpty)
    await store.finish()
  }

  @Test(.dependencies) func repositoryLocalSettingsOverrideGlobalRepositorySettings() async throws {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(worktree: worktree)
    let settingsStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(
      fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json"
    )
    let repositoryID = worktree.repositoryRootURL.standardizedFileURL.path(percentEncoded: false)
    var globalRepositorySettings = RepositorySettings.default
    globalRepositorySettings.openActionID = OpenWorktreeAction.finder.settingsID
    var localRepositorySettings = RepositorySettings(
      setupScript: "",
      archiveScript: "",
      deleteScript: "",
      runScript: "pnpm dev",
      scripts: [ScriptDefinition(kind: .run, command: "pnpm dev")],
      openActionID: OpenWorktreeAction.terminal.settingsID,
      worktreeBaseRef: nil
    )

    withDependencies {
      $0.settingsFileStorage = settingsStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock {
        $0.repositories[repositoryID] = globalRepositorySettings
      }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try localStorage.save(
      encoder.encode(localRepositorySettings),
      at: SupacodePaths.repositorySettingsURL(for: worktree.repositoryRootURL)
    )

    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.settingsFileStorage = settingsStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    }

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree)))) {
      $0.repositories.$sidebar.withLock { sidebar in
        sidebar.focusedWorktreeID = worktree.id
      }
    }
    await store.receive(\.worktreeSettingsLoaded) {
      $0.loadedRepoScripts = LoadedRepositoryScripts(
        scripts: localRepositorySettings.scripts,
        rootURL: worktree.repositoryRootURL,
        host: worktree.host
      )
    }

    // `openActionSelection` reads the resolved map, so resolve it. The local
    // `supacode.json` says Terminal and the global entry says Finder: local wins, but
    // only the pass can see the file, so the seed answers Finder from the global entry.
    let repository = store.state.repositories.repositories[0]
    await store.send(.repositories(.resolveOpenActions)) {
      $0.repositories.openActionByRepositoryID = [repository.id: .finder]
    }
    await store.receive(\.repositories.openActionsResolved) {
      $0.repositories.openActionByRepositoryID = [repository.id: .terminal]
    }
    #expect(store.state.openActionSelection == .terminal)
    await store.finish()
  }

  /// The settings load is async, so a selection that moves to another repository must
  /// drop the previous one's scripts on the spot. The toolbar renders `repoScripts`
  /// live, and running one in the gap would fire the old repository's command inside
  /// the newly selected worktree's shell.
  @Test(.dependencies) func selectingAnotherRepositoryDropsThePreviousRepositorysScripts() async {
    let worktree = makeWorktree()
    let otherRoot = URL(fileURLWithPath: "/tmp/other-repo")
    let otherWorktree = Worktree(
      id: WorktreeID(otherRoot.path(percentEncoded: false)),
      name: "other",
      detail: "detail",
      workingDirectory: otherRoot,
      repositoryRootURL: otherRoot
    )
    let script = ScriptDefinition(kind: .run, command: "npm run dev")

    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    initialState.loadedRepoScripts = LoadedRepositoryScripts(
      scripts: [script],
      rootURL: worktree.repositoryRootURL,
      host: worktree.host
    )

    let store = TestStore(initialState: initialState) { AppFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(otherWorktree)))) {
      $0.loadedRepoScripts = nil
    }
    await store.finish()
  }

  /// The open action follows the selection immediately, with no window in which it still
  /// names the previously selected repository's editor. It is read from the resolved map,
  /// which is per repository and already current, rather than refreshed by the settings
  /// load that lands a disk read later.
  @Test(.dependencies) func openActionFollowsTheSelectionWithNoStaleWindow() {
    let worktree = makeWorktree()
    let otherRoot = URL(fileURLWithPath: "/tmp/other-repo")
    let otherWorktree = Worktree(
      id: WorktreeID(otherRoot.path(percentEncoded: false)),
      name: "other",
      detail: "detail",
      workingDirectory: otherRoot,
      repositoryRootURL: otherRoot
    )
    let otherRepository = Repository(
      id: RepositoryID(otherRoot.path(percentEncoded: false)),
      rootURL: otherRoot,
      name: "other",
      worktrees: [otherWorktree]
    )

    var repositoriesState = makeRepositoriesState(worktree: worktree)
    let repository = repositoriesState.repositories[0]
    repositoriesState.repositories.append(otherRepository)
    repositoriesState.installedOpenActions = [.zed, .cursor, .finder]
    repositoriesState.openActionByRepositoryID = [repository.id: .zed, otherRepository.id: .cursor]

    var state = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    state.installedOpenActions = [.zed, .cursor, .finder]
    #expect(state.openActionSelection == .zed)

    // Moving the selection is enough. Nothing has to load, and no effect has to land,
    // so there is no interval in which this still reports the previous repository's Zed.
    state.repositories.selection = .worktree(otherWorktree.id)
    #expect(state.openActionSelection == .cursor)
  }

  /// An empty `repoScripts` is ambiguous while the settings are in flight: it reads as
  /// "this repository configures no run script", which is the cue to fall back to the
  /// global one. Running that would be the wrong script, so `⌘R` waits for the load
  /// rather than acting on a repository whose scripts have not been read yet.
  @Test(.dependencies) func runScriptWaitsForTheSelectedRepositorysScriptsToLoad() async {
    let worktree = makeWorktree()
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    initialState.globalScripts = [ScriptDefinition(kind: .run, command: "make serve")]
    initialState.loadedRepoScripts = nil

    let store = TestStore(initialState: initialState) { AppFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // The global run script is right there and must not be taken.
    #expect(store.state.primaryScript?.command == "make serve")
    await store.send(.runScript)
    await store.finish()
  }

  /// The other half of the same rule: worktrees of one repository share its
  /// `supacode.json`, so moving between them serves identical scripts. Clearing there
  /// would blank the Run button on every arrow key for no correctness gain.
  @Test(.dependencies) func selectingASiblingWorktreeKeepsTheRepositorysScripts() async {
    let worktree = makeWorktree()
    // Same repository root, so the same `supacode.json` and the same scripts.
    let sibling = Worktree(
      id: WorktreeID("/tmp/repo/sibling"),
      name: "sibling",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/sibling"),
      repositoryRootURL: worktree.repositoryRootURL
    )
    let script = ScriptDefinition(kind: .run, command: "npm run dev")
    let source = RepositorySettingsKey(rootURL: worktree.repositoryRootURL, host: nil).id

    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    initialState.loadedRepoScripts = LoadedRepositoryScripts(
      scripts: [script],
      rootURL: worktree.repositoryRootURL,
      host: worktree.host
    )

    let store = TestStore(initialState: initialState) { AppFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(sibling))))
    #expect(store.state.repoScripts == [script])
    #expect(store.state.loadedRepoScripts?.source == source)
    await store.finish()
  }

  /// A `supacode.json` can change while the user is out of the app (a `git pull`,
  /// a hand edit, another tool). Resolution is cached in the reducer, so activation
  /// has to re-read every repository or the context menu would serve the stale open
  /// action until the next relaunch.
  @Test(.dependencies) func activationPicksUpAnOutOfBandRepositorySettingsEdit() async throws {
    let worktree = makeWorktree()
    let repoRoot = worktree.repositoryRootURL
    let repositoriesState = makeRepositoriesState(worktree: worktree)
    let settingsStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let repositoryID = repositoriesState.repositories[0].id
    let localSettingsURL = SupacodePaths.repositorySettingsURL(for: repoRoot)
    let encoder = JSONEncoder()

    var localSettings = RepositorySettings.default
    localSettings.openActionID = OpenWorktreeAction.terminal.settingsID
    try localStorage.save(encoder.encode(localSettings), at: localSettingsURL)

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: SettingsFeature.State())
    ) {
      AppFeature()
    } withDependencies: {
      $0.settingsFileStorage = settingsStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
      $0.date = DateGenerator { Date(timeIntervalSince1970: 1_000) }
      $0.analyticsClient.capture = { _, _ in }
      // Activation also kicks the debounced editor-availability sweep.
      $0.continuousClock = ImmediateClock()
    }

    await store.send(.applicationDidBecomeActive) {
      $0.appLifecycleEventDebouncer.lastActivatedAt = Date(timeIntervalSince1970: 1_000)
    }
    await store.receive(\.repositories.resolveOpenActions) {
      // Seeded from memory: no settings-file entry and no default editor, so the
      // preferred installed one. Only the pass can see `supacode.json`.
      $0.repositories.openActionByRepositoryID = [repositoryID: .zed]
    }
    await store.receive(\.repositories.openActionsResolved) {
      $0.repositories.openActionByRepositoryID = [repositoryID: .terminal]
    }

    // The file changes behind the app's back.
    localSettings.openActionID = OpenWorktreeAction.zed.settingsID
    try localStorage.save(encoder.encode(localSettings), at: localSettingsURL)

    await store.send(.applicationDidBecomeActive)
    await store.receive(\.repositories.resolveOpenActions)
    await store.receive(\.repositories.openActionsResolved) {
      $0.repositories.openActionByRepositoryID = [repositoryID: .zed]
    }
    await store.finish()
  }

  /// An editor can be installed from a Supacode terminal (`brew install --cask …`),
  /// which never takes the app inactive. Availability used to be probed live on every
  /// menu build, so that just worked; now it is a cached sweep and the periodic
  /// refresh has to ask for one, or the new editor never reaches the menus.
  @Test(.dependencies) func periodicRefreshResweepsInstalledEditors() async {
    let installed = LockIsolated<[OpenWorktreeAction]>([.finder])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.openActionAvailability.installedActions = { installed.value }
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Cursor lands while the app stays active, so no activation can pick it up.
    installed.withValue { $0 = [.cursor, .finder] }

    await store.send(.refreshInstalledOpenActions)
    await store.receive(\.installedOpenActionsResolved) {
      $0.installedOpenActions = [.cursor, .finder]
      $0.settings.installedOpenActions = [.cursor, .finder]
    }
    await store.finish()
  }

  @Test(.dependencies) func selectedWorktreeChangedOnlyUpdatesWatcherSelection() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(worktree: worktree)
    @Dependency(\.openActionAvailability) var openActionAvailability
    let expectedOpenActionSelection = OpenWorktreeAction.preferredDefault(
      installed: openActionAvailability.installedActions()
    )
    let watcherCommands = LockIsolated<[WorktreeInfoWatcherClient.Command]>([])
    let storage = SettingsTestStorage()
    let settingsFileURL = URL(
      fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json"
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
      $0.worktreeInfoWatcher.send = { command in
        watcherCommands.withValue { $0.append(command) }
      }
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
    }

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree)))) {
      $0.repositories.$sidebar.withLock { sidebar in
        sidebar.focusedWorktreeID = worktree.id
      }
    }
    await store.receive(\.worktreeSettingsLoaded) {
      $0.loadedRepoScripts = LoadedRepositoryScripts(
        scripts: [],
        rootURL: worktree.repositoryRootURL,
        host: worktree.host
      )
    }
    // Nothing resolved into the map, so the selection falls back to the installed default.
    #expect(store.state.openActionSelection == expectedOpenActionSelection)
    await store.finish()

    #expect(watcherCommands.value == [.setSelectedWorktreeID(worktree.id)])
  }

  @Test(.dependencies) func openAndRevealWithFinderReportUnsupportedForRemoteWorktree() async {
    let config = TestRemoteRepo(
      host: RemoteHost(alias: "devbox"),
      remotePath: "/home/me/proj",
      displayName: "proj"
    )
    let worktree = RepositoriesFeature.remoteMainWorktree(config: config)
    let repository = Repository(
      id: RepositoriesFeature.remoteRepositoryID(for: config),
      rootURL: URL(fileURLWithPath: config.normalizedRemotePath),
      name: config.resolvedDisplayName,
      worktrees: IdentifiedArray(uniqueElements: [worktree]),
      isGitRepository: true,
      host: config.host
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)

    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: SettingsFeature.State())
    ) {
      AppFeature()
    }

    // Finder can't reach a remote path, so both routes reject the open, but a
    // hotkey / deeplink still gets an explanatory alert instead of silence.
    let expectedAlert = AlertState<AppFeature.Alert> {
      TextState("Can't reveal remote worktree")
    } actions: {
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("OK")
      }
    } message: {
      TextState("Reveal in Finder isn't available for remote SSH worktrees.")
    }
    await store.send(.openWorktree(.finder))
    await store.receive(\.openWorktreeFailed) { $0.alert = expectedAlert }
    await store.send(.revealInFinder)
    await store.receive(\.openWorktreeFailed)
    await store.finish()
  }

  /// Every open surface still has to name an editor before the resolution pass lands.
  /// Skipping to the preferred installed one ignores the user's default editor, so the
  /// menus would offer Cursor and flip to Zed the moment the pass landed.
  @Test(.dependencies) func theFallbackBeforeResolutionHonorsTheDefaultEditor() {
    let installed: [OpenWorktreeAction] = [.cursor, .zed, .finder]
    let worktree = makeWorktree()
    var repositoriesState = makeRepositoriesState(worktree: worktree)
    repositoriesState.installedOpenActions = installed
    // Nothing has resolved for this repository yet: a cold launch, or one just added.
    repositoriesState.openActionByRepositoryID = [:]

    var settings = GlobalSettings.default
    settings.defaultEditorID = OpenWorktreeAction.zed.settingsID
    var state = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State(settings: settings)
    )
    state.installedOpenActions = installed

    #expect(OpenWorktreeAction.preferredDefault(installed: installed) == .cursor)
    #expect(state.openActionSelection == .zed)
  }

  /// A repository with no `supacode.json` keeps its open action in the settings file, so
  /// that entry is the normal case, not an edge one. Seeding only from the default editor
  /// would offer Cursor to a repository the user set to Zed until the disk pass landed,
  /// and ⌘O in that window opens what the menu says.
  @Test(.dependencies) func theSeedHonorsTheRepositorysSettingsFileEntry() async {
    let installed: [OpenWorktreeAction] = [.cursor, .zed, .finder]
    let worktree = makeWorktree()
    let rootURL = worktree.repositoryRootURL
    let storage = SettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")

    let repositoriesState = makeRepositoriesState(worktree: worktree)
    let repository = repositoriesState.repositories[0]

    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
      // `AppFeature.State.init` seeds the installed set from here, so this is the only
      // place that reaches the seed. Cursor has to be installed for the assertion below
      // to mean anything: it is what the seed lands on if it reads only the default
      // editor and skips the repository's settings-file entry.
      $0.openActionAvailability.installedActions = { installed }
    } operation: {
      var global = GlobalSettings.default
      global.defaultEditorID = OpenWorktreeAction.cursor.settingsID
      var repositorySettings = RepositorySettings.default
      repositorySettings.openActionID = OpenWorktreeAction.zed.settingsID
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock {
        $0.global = global
        $0.repositories[RepositorySettingsKey(rootURL: rootURL).repositoryID] = repositorySettings
      }
      let state = AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State(settings: global)
      )
      return TestStore(initialState: state) { AppFeature() }
    }
    store.exhaustivity = .off
    #expect(store.state.repositories.installedOpenActions == installed)

    // The map is empty, and nothing has read a file yet.
    #expect(store.state.repositories.openActionByRepositoryID.isEmpty)

    await store.send(.repositories(.resolveOpenActions))
    #expect(store.state.repositories.openActionByRepositoryID[repository.id] == .zed)
    await store.finish()
  }

  /// The repository's shared reference is cached and `save` encodes the whole struct, so
  /// changing the open action through it writes back the file as it was when the terminal
  /// opened. Anything the repository's `supacode.json` gained since (an agent adding a
  /// script, a `git pull`) would be gone.
  @Test(.dependencies) func changingTheOpenActionKeepsWhatTheFileGainedOutOfBand() async {
    let worktree = makeWorktree()
    let rootURL = worktree.repositoryRootURL
    let localURL = SupacodePaths.repositorySettingsURL(for: rootURL)
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let encoder = JSONEncoder()

    var onDisk = RepositorySettings.default
    onDisk.setupScript = "echo setup"
    try? localStorage.save(encoder.encode(onDisk), at: localURL)

    let (store, pinned) = withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: { () -> (TestStore<AppFeature.State, AppFeature.Action>, Shared<RepositorySettings>) in
      // Held for the rest of the test, the way a live terminal holds its worktree's
      // reader: it pins the cache entry, so nothing re-reads the file through it.
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      let store = TestStore(
        initialState: AppFeature.State(
          repositories: makeRepositoriesState(worktree: worktree),
          settings: SettingsFeature.State()
        )
      ) {
        AppFeature()
      }
      return (store, $repositorySettings)
    }
    #expect(pinned.wrappedValue.setupScript == "echo setup")

    // The file gains a script out of band, after the reference cached the old contents.
    var edited = onDisk
    edited.scripts = [ScriptDefinition(kind: .run, command: "echo agent")]
    try? localStorage.save(encoder.encode(edited), at: localURL)

    store.exhaustivity = .off
    await store.send(.openActionSelectionChanged(.zed))
    await store.finish()

    let written = localStorage.data(at: localURL)
    let saved = try? JSONDecoder().decode(RepositorySettings.self, from: written ?? Data())
    #expect(saved?.openActionID == OpenWorktreeAction.zed.settingsID)
    #expect(saved?.scripts == edited.scripts)
    #expect(saved?.setupScript == "echo setup")
  }

  private func makeWorktree() -> Worktree {
    let repositoryRootURL = URL(fileURLWithPath: "/tmp/repo-\(UUID().uuidString)")
    let worktreeURL = repositoryRootURL.appending(path: "wt-1")
    return Worktree(
      id: WorktreeID(worktreeURL.path(percentEncoded: false)),
      name: "wt-1",
      detail: "detail",
      workingDirectory: worktreeURL,
      repositoryRootURL: repositoryRootURL
    )
  }

  private func makeRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    let repository = Repository(
      id: RepositoryID(worktree.repositoryRootURL.path(percentEncoded: false)),
      rootURL: worktree.repositoryRootURL,
      name: "repo",
      worktrees: [worktree]
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    return repositoriesState
  }
}
