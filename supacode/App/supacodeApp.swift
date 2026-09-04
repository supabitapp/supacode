//
//  supacodeApp.swift
//  supacode
//
//  Created by khoi on 20/1/26.
//

import AppKit
import ComposableArchitecture
import Foundation
import GhosttyKit
import IdentifiedCollections
import OrderedCollections
import Sharing
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

private enum GhosttyCLI {
  // Bare executable only: this argv is inert on macOS (Ghostty reads CLI args
  // from `NSProcessInfo`), so keybinds ship via the bundled config file.
  static let argv: [UnsafeMutablePointer<CChar>?] = {
    let executable = CommandLine.arguments.first ?? "supacode"
    return [strdup(executable), nil]
  }()
}

@MainActor
final class SupacodeAppDelegate: NSObject, NSApplicationDelegate {
  var appStore: StoreOf<AppFeature>? {
    didSet {
      guard let appStore else { return }
      // Replay any deeplinks that arrived before the store was initialized.
      let buffered = bufferedDeeplinkURLs
      bufferedDeeplinkURLs.removeAll()
      for url in buffered {
        appStore.send(.deeplinkReceived(url))
      }
      // Route taps on delivered system notifications through the store
      // so they follow the same dispatch path as URL-scheme deeplinks.
      setSystemNotificationTapHandler { [weak appStore] url in
        appStore?.send(.deeplinkReceived(url))
      }
    }
  }
  var terminalManager: WorktreeTerminalManager?
  var globalHotkeyMonitor: GlobalHotkeyMonitor?
  private var bufferedDeeplinkURLs: [URL] = []

  func applicationWillTerminate(_ notification: Notification) {
    // Release the global Carbon registration explicitly rather than leaning on
    // deinit timing.
    globalHotkeyMonitor?.tearDown()
    // Drop the queued debounce timers; a flush already on the writer's serial
    // queue still completes, but the terminal write below runs on that same queue
    // and is therefore ordered strictly after it, never regressed by a late flush.
    // The on-quit save embeds agent records so badges survive relaunch (agents
    // only emit session_start once per process lifetime), and a second concurrent
    // instance overwriting the file is an accepted dev-only last-writer-wins window.
    terminalManager?.cancelPendingLayoutSaves()
    let agentsBySurface = appStore?.state.agentPresence.agentsBySurface() ?? [:]
    terminalManager?.saveAllLayoutSnapshots(agentsBySurface: agentsBySurface)
    terminalManager?.rememberSelectedWorktreeZoomOnQuit()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Disable press-and-hold accent menu so that key repeat works in the terminal.
    UserDefaults.standard.register(defaults: [
      "ApplePressAndHoldEnabled": false
    ])
    // `NSColorPanel.shared` is `isRestorable = true` by default, so
    // the system writes its visibility to the app's restoration
    // archive and brings it back on next launch — independently of
    // the main window. Opt the singleton out per-process so a panel
    // left open from a previous session can't survive the relaunch.
    NSColorPanel.shared.isRestorable = false
    guard let appStore else {
      SupaLogger("App").error("applicationDidFinishLaunching with no store; launch setup skipped.")
      return
    }
    // Apply the saved Dock/menu-bar visibility before the first window shows.
    NSApplication.shared.applyActivationPolicy(for: appStore.state.settings.appVisibility)
    appStore.send(.appLaunched)
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    appStore?.send(.applicationDidBecomeActive)
    let app = NSApplication.shared
    let hasVisibleMainWindow = app.windows.contains { window in
      window.isVisible && window.isSurfaceableAppWindow
    }
    guard !hasVisibleMainWindow else { return }
    app.surfaceMainWindow()
  }

  func applicationDidResignActive(_ notification: Notification) {
    appStore?.send(.applicationDidResignActive)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if flag { return true }
    return !sender.surfaceMainWindow()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard let appStore else {
      SupaLogger("Deeplink").warning("Deeplink received before store initialized, buffering: \(urls)")
      bufferedDeeplinkURLs.append(contentsOf: urls)
      return
    }
    for url in urls {
      appStore.send(.deeplinkReceived(url))
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}

@main
@MainActor
struct SupacodeApp: App {
  @NSApplicationDelegateAdaptor(SupacodeAppDelegate.self) private var appDelegate
  @State private var ghostty: GhosttyRuntime
  @State private var ghosttyShortcuts: GhosttyShortcutManager
  @State private var terminalManager: WorktreeTerminalManager
  @State private var worktreeInfoWatcher: WorktreeInfoWatcherManager
  @State private var commandKeyObserver: CommandKeyObserver
  @State private var globalHotkeyMonitor: GlobalHotkeyMonitor
  @State private var openActionIcons = OpenActionIconStore()
  @State private var store: StoreOf<AppFeature>

  @MainActor init() {
    NSWindow.allowsAutomaticWindowTabbing = false
    UserDefaults.standard.set(200, forKey: "NSInitialToolTipDelay")
    // Relocate config out of `~/.supacode` into `~/.config/supacode` and move
    // sidebar / layouts into UserDefaults. Never throws; the underlying data is
    // always preserved in place, so a partial failure only defers cleanup and is
    // surfaced to the user below.
    let relocationOutcome = SettingsRelocationMigrator.run()
    @Shared(.settingsFile) var settingsFile
    let initialSettings = settingsFile.global
    let infoDictionary = Bundle.main.infoDictionary ?? [:]
    AppCrashReporting.setup(settings: initialSettings, infoDictionary: infoDictionary)
    AppTelemetry.setup(settings: initialSettings, infoDictionary: infoDictionary)
    if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("ghostty") {
      setenv("GHOSTTY_RESOURCES_DIR", resourceURL.path, 1)
    }
    GhosttyCLI.argv.withUnsafeBufferPointer { buffer in
      let argc = UInt(max(0, buffer.count - 1))
      let argv = UnsafeMutablePointer(mutating: buffer.baseAddress)
      if ghostty_init(argc, argv) != GHOSTTY_SUCCESS {
        preconditionFailure("ghostty_init failed")
      }
    }
    let runtime = GhosttyRuntime()
    _ghostty = State(initialValue: runtime)
    let shortcuts = GhosttyShortcutManager(runtime: runtime)
    _ghosttyShortcuts = State(initialValue: shortcuts)
    let terminalManager = Self.makeTerminalManager(runtime: runtime)
    _terminalManager = State(initialValue: terminalManager)
    // Seed the flag at construction so a user who disabled background refresh
    // never eats a launch-time SSH / gh burst before the setting is applied.
    let worktreeInfoWatcher = WorktreeInfoWatcherManager(
      automaticRefreshEnabled: initialSettings.automaticRepositoryRefreshEnabled,
      reconcileInterval: .seconds(initialSettings.automaticRepositoryRefreshInterval)
    )
    _worktreeInfoWatcher = State(initialValue: worktreeInfoWatcher)
    let keyObserver = CommandKeyObserver()
    _commandKeyObserver = State(initialValue: keyObserver)
    // Windowed panes host the same strip views, which read these from the
    // environment; the app shell is the only place both exist.
    terminalManager.paneWindows.ghosttyShortcuts = shortcuts
    terminalManager.paneWindows.commandKeyObserver = keyObserver
    let hotkeyMonitor = GlobalHotkeyMonitor()
    _globalHotkeyMonitor = State(initialValue: hotkeyMonitor)
    let appStore = Self.makeStore(
      initialSettings: initialSettings,
      runtime: runtime,
      terminalManager: terminalManager,
      worktreeInfoWatcher: worktreeInfoWatcher,
      globalHotkeyMonitor: hotkeyMonitor
    )
    _store = State(initialValue: appStore)
    appDelegate.appStore = appStore
    appDelegate.terminalManager = terminalManager
    appDelegate.globalHotkeyMonitor = hotkeyMonitor
    terminalManager.appStore = appStore
    // Surface a partial-relocation failure once the store exists so the alert
    // presents on first window. The data is preserved regardless.
    if case .pending(let problems) = relocationOutcome {
      appStore.send(.settingsRelocationDidNotFinish(problems: problems))
    }
    // If a settings file was present but unreadable this launch, the store loaded
    // degraded and refuses saves; tell the user their changes won't stick until
    // they relaunch, rather than letting edits silently evaporate.
    @Dependency(\.settingsStoreHealth) var settingsStoreHealth
    if settingsStoreHealth.isDegraded(.live) {
      appStore.send(.settingsStoreUnreadable)
    }
    Self.hydrateLayouts(into: appStore)
    // Source live agent badge records for incremental layout captures; the [:]
    // default would clobber badges that share a surface key on every save.
    terminalManager.currentAgentsBySurface = { [weak appStore] in
      appStore?.state.agentPresence.agentsBySurface() ?? [:]
    }
    Self.configureSocketHandlers(terminalManager: terminalManager, store: appStore)
  }

  @MainActor
  private static func makeTerminalManager(runtime: GhosttyRuntime) -> WorktreeTerminalManager {
    let terminalManager = WorktreeTerminalManager(runtime: runtime)
    runtime.focusedSurfaceBackgroundColorProvider = { [weak terminalManager] in
      terminalManager?.focusedSurfaceBackground
    }
    return terminalManager
  }

  /// Serves the persisted layouts to `TerminalsFeature`. A still-v1 file (a
  /// deferred migration) is migrated in memory as a safety net; the writer
  /// then drops flushes until the on-disk migration succeeds, so the v1 bytes
  /// survive for the next launch.
  @MainActor
  private static func hydrateLayouts(into store: StoreOf<AppFeature>) {
    @Dependency(\.defaultAppStorage) var defaults
    guard case .file(let file) = LayoutsFile.readPersisted(from: defaults) else { return }
    store.send(.terminals(.layoutsHydrated(file)))
  }

  @MainActor
  private static func makeStore(
    initialSettings: GlobalSettings,
    runtime: GhosttyRuntime,
    terminalManager: WorktreeTerminalManager,
    worktreeInfoWatcher: WorktreeInfoWatcherManager,
    globalHotkeyMonitor: GlobalHotkeyMonitor
  ) -> StoreOf<AppFeature> {
    Store(initialState: AppFeature.State(settings: SettingsFeature.State(settings: initialSettings))) {
      AppFeature()
        .logActions()
    } withDependencies: { values in
      // Inject the app-owned monitor so the reducer's register/unregister
      // intent reaches the single Carbon instance created at launch.
      values.appLifecycleClient.updateGlobalHotkey = { globalHotkeyMonitor.apply($0) }
      values[LayoutContentFactory.self] = Self.makeContentFactory(
        runtime: runtime,
        terminalManager: terminalManager
      )
      values[ContentSessionKiller.self] = ContentSessionKiller(
        kill: { contentID, worktreeID in
          await terminalManager.killSession(for: contentID, worktreeID: worktreeID)
        }
      )
      values[SplitZoomPolicy.self] = SplitZoomPolicy(
        preservesZoomOnNavigation: { runtime.splitPreserveZoomOnNavigation() }
      )
      values[LayoutChangeObserver.self] = LayoutChangeObserver(
        layoutChanged: { worktreeID in
          terminalManager.handleLayoutChanged(for: worktreeID)
        }
      )
      values.terminalClient = TerminalClient(
        send: { command in
          terminalManager.handleCommand(command)
        },
        events: {
          terminalManager.eventStream()
        },
        tabExists: { worktreeID, tabID in
          terminalManager.tabExists(worktreeID: worktreeID, tabID: tabID)
        },
        tabCanRename: { worktreeID, tabID in
          terminalManager.tabCanRename(worktreeID: worktreeID, tabID: tabID)
        },
        surfaceExists: { worktreeID, tabID, surfaceID in
          terminalManager.surfaceExists(worktreeID: worktreeID, tabID: tabID, surfaceID: surfaceID)
        },
        surfaceExistsInWorktree: { worktreeID, surfaceID in
          terminalManager.surfaceExistsInWorktree(worktreeID: worktreeID, surfaceID: surfaceID)
        },
        idExistsAnywhere: { id in
          terminalManager.idExistsAnywhere(id)
        },
        paneExists: { worktreeID, token in
          terminalManager.paneExists(worktreeID: worktreeID, token: token)
        },
        canMoveTabToNewSplit: { worktreeID, tabID in
          terminalManager.canMoveTabToNewSplit(worktreeID: worktreeID, tabID: tabID)
        },
        tabID: { worktreeID, surfaceID in
          terminalManager.tabID(forWorktreeID: worktreeID, surfaceID: surfaceID)
        },
        selectedTabID: { worktreeID in
          terminalManager.hostIfExists(for: worktreeID)?.focusedTab?.id
        },
        selectedSurfaceID: { worktreeID in
          terminalManager.hostIfExists(for: worktreeID)?.focusedContentID
        },
        latestUnreadNotification: {
          terminalManager.latestUnreadNotificationLocation()
        },
        markNotificationRead: { worktreeID, notificationID in
          terminalManager.markNotificationRead(worktreeID: worktreeID, notificationID: notificationID)
        },
        markAllNotificationsRead: {
          terminalManager.markAllNotificationsRead()
        },
        hasInflightBlockingScripts: {
          terminalManager.hasInflightBlockingScripts
        },
        terminateAllSessions: {
          await terminalManager.terminateAllSessions()
        },
        reapOrphanSessions: { knownSurfaceIDs in
          await terminalManager.reapOrphanSessions(knownSurfaceIDs: knownSurfaceIDs)
        },
        saveLayoutsWithAgents: { agentsBySurface in
          terminalManager.saveAllLayoutSnapshots(agentsBySurface: agentsBySurface)
        }
      )
      values.worktreeInfoWatcher = WorktreeInfoWatcherClient(
        send: { command in
          worktreeInfoWatcher.handleCommand(command)
        },
        events: {
          worktreeInfoWatcher.eventStream()
        }
      )
      // Bridge the archived-worktree timestamps from the canonical
      // `@Shared(.sidebar)` bucket into the `SupacodeSettingsShared`
      // package, which cannot see `SidebarState` directly. The
      // settings auto-delete preflight uses this to decide whether
      // to show a destructive-confirmation alert before shortening
      // the retention window.
      values.archivedWorktreeDatesClient = ArchivedWorktreeDatesClient(
        load: {
          @Shared(.sidebar) var sidebar: SidebarState
          return sidebar.archivedWorktrees.map(\.archivedAt)
        }
      )
      // Force the live continuous clock so the agent-presence liveness
      // sweep (`AgentPresenceFeature.start`) doesn't trip the unimplemented
      // test clock when the app shell happens to launch inside an XCTest
      // process. Tests that take a TestStore for AppFeature inject their
      // own clock and still override this.
      values.continuousClock = ContinuousClock()
    }
  }

  /// The live content factory: terminal surfaces built from a freshly
  /// resolved plan, wired into the worktree's host and layout conduit.
  @MainActor
  private static func makeContentFactory(
    runtime: GhosttyRuntime,
    terminalManager: WorktreeTerminalManager
  ) -> LayoutContentFactory {
    TerminalContentBuilder(
      runtime: runtime,
      worktree: { [weak terminalManager] id in
        terminalManager?.appStore?.withState { $0.repositories.worktree(for: id) }
      },
      socketPath: { [weak terminalManager] in
        terminalManager?.socketServer?.socketPath
      },
      zmxExecutablePath: {
        @Dependency(\.zmxClient) var zmxClient
        return zmxClient.executableURL()?.path(percentEncoded: false)
      },
      sourceSurface: { id in
        ContentRuntime.liveValue.content(for: id)?.renderer as? GhosttySurfaceView
      },
      wireSurface: { [weak terminalManager] view, request in
        guard let terminalManager,
          let worktree = terminalManager.appStore?.withState({
            $0.repositories.worktree(for: request.worktreeID)
          })
        else { return }
        let host = terminalManager.host(for: worktree)
        LayoutSurfaceConduit(
          host: host,
          runtime: ContentRuntime.liveValue,
          handleUnexpectedZmxClose: { [weak terminalManager] view in
            terminalManager?.handleUnexpectedZmxClose(view, worktreeID: worktree.id)
          }
        ).wire(view, contentID: request.contentID)
      },
      environmentExtras: { [weak terminalManager] request in
        terminalManager?.hostIfExists(for: request.worktreeID)?
          .blockingScriptEnvironment(for: request.tabID) ?? [:]
      }
    ).factory()
  }

  @MainActor
  private static func configureSocketHandlers(
    terminalManager: WorktreeTerminalManager,
    store: StoreOf<AppFeature>
  ) {
    terminalManager.onDeeplinkCommand = { url, clientFD in
      store.send(.deeplinkReceived(url, source: .socket, responseFD: clientFD))
    }
    terminalManager.onQuery = { resource, params, clientFD in
      Self.handleQuery(
        resource: resource,
        params: params,
        clientFD: clientFD,
        terminalManager: terminalManager,
        store: store
      )
    }
    // Kicked off here rather than from `.appLaunched` so unit tests that
    // never construct a real AppFeature store (or that boot the app shell
    // under XCTest) don't spin the 2s liveness timer against the
    // dependency-test clock.
    store.send(.agentPresence(.start))
  }

  @MainActor
  private static func handleQuery(
    resource: String,
    params: [String: String],
    clientFD: Int32,
    terminalManager: WorktreeTerminalManager,
    store: StoreOf<AppFeature>
  ) {
    let repos = store.repositories.repositories
    let selectedWorktreeID = store.repositories.selectedWorktreeID

    switch resource {
    case "repos":
      let data = repos.map {
        ["id": WorktreeStatusQueryResponse.encoded(id: $0.id.rawValue)]
      }
      AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: data)
    case "worktrees":
      let repositories = store.repositories
      let data = repos.flatMap { repository in
        repository.worktrees.map { worktree in
          WorktreeStatusQueryResponse.listFields(
            worktreeID: worktree.id,
            status: repositories.sidebar.status(
              of: worktree.id,
              in: repository.id,
              isMain: repositories.isMainWorktree(worktree)
            ),
            isFocused: worktree.id == selectedWorktreeID
          )
        }
      }
      AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: data)
    case "tabs":
      guard let worktreeID = params["worktreeID"] else {
        AgentHookSocketServer.sendCommandResponse(
          clientFD: clientFD, ok: false, error: "Missing worktreeID for tab list.")
        return
      }
      let tabs = terminalManager.listTabs(worktreeID: worktreeID)
      if tabs == nil {
        let decoded = worktreeID.removingPercentEncoding ?? worktreeID
        let worktreeExists = repos.contains { $0.worktrees.contains { $0.id.rawValue == decoded } }
        guard worktreeExists else {
          AgentHookSocketServer.sendCommandResponse(
            clientFD: clientFD, ok: false, error: "Worktree not found: \(worktreeID)")
          return
        }
      }
      AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: tabs ?? [])
    case "panes":
      handlePanesQuery(
        params: params, repos: repos, clientFD: clientFD, terminalManager: terminalManager)
    case "surfaces":
      guard let worktreeID = params["worktreeID"], let tabID = params["tabID"] else {
        AgentHookSocketServer.sendCommandResponse(
          clientFD: clientFD, ok: false, error: "Missing worktreeID/tabID for surface list.")
        return
      }
      guard let surfaces = terminalManager.listSurfaces(worktreeID: worktreeID, tabID: tabID) else {
        AgentHookSocketServer.sendCommandResponse(
          clientFD: clientFD, ok: false, error: "Worktree or tab not found.")
        return
      }
      AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: surfaces)
    case "worktreeStatus":
      handleWorktreeStatusQuery(params: params, repos: repos, clientFD: clientFD, store: store)
    case "worktreeAppearance":
      handleWorktreeAppearanceQuery(params: params, repos: repos, clientFD: clientFD, store: store)
    case "scripts":
      handleScriptsQuery(params: params, repos: repos, clientFD: clientFD, store: store)
    default:
      AgentHookSocketServer.sendCommandResponse(
        clientFD: clientFD, ok: false, error: "Unknown resource: \(resource)")
    }
  }

  private static func handlePanesQuery(
    params: [String: String],
    repos: IdentifiedArrayOf<Repository>,
    clientFD: Int32,
    terminalManager: WorktreeTerminalManager
  ) {
    guard let worktreeID = params["worktreeID"] else {
      AgentHookSocketServer.sendCommandResponse(
        clientFD: clientFD, ok: false, error: "Missing worktreeID for pane list.")
      return
    }
    let panes = terminalManager.listPanes(worktreeID: worktreeID)
    if panes == nil {
      let decoded = worktreeID.removingPercentEncoding ?? worktreeID
      let worktreeExists = repos.contains { $0.worktrees.contains { $0.id.rawValue == decoded } }
      guard worktreeExists else {
        AgentHookSocketServer.sendCommandResponse(
          clientFD: clientFD, ok: false, error: "Worktree not found: \(worktreeID)")
        return
      }
    }
    AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: panes ?? [])
  }

  private static func handleWorktreeStatusQuery(
    params: [String: String],
    repos: IdentifiedArrayOf<Repository>,
    clientFD: Int32,
    store: StoreOf<AppFeature>
  ) {
    guard let worktreeID = params["worktreeID"] else {
      AgentHookSocketServer.sendCommandResponse(
        clientFD: clientFD, ok: false, error: "Missing worktreeID for status.")
      return
    }
    guard let (repository, worktree) = resolveWorktree(worktreeID, in: repos) else {
      AgentHookSocketServer.sendCommandResponse(
        clientFD: clientFD, ok: false, error: "Worktree not found: \(worktreeID)")
      return
    }
    let repositories = store.repositories
    AgentHookSocketServer.sendQueryResponse(
      clientFD: clientFD,
      data: [
        WorktreeStatusQueryResponse.statusFields(
          status: repositories.sidebar.status(
            of: worktree.id,
            in: repository.id,
            isMain: repositories.isMainWorktree(worktree)
          ),
          isFocused: worktree.id == repositories.selectedWorktreeID
        )
      ]
    )
  }

  private static func handleWorktreeAppearanceQuery(
    params: [String: String],
    repos: IdentifiedArrayOf<Repository>,
    clientFD: Int32,
    store: StoreOf<AppFeature>
  ) {
    guard let worktreeID = params["worktreeID"] else {
      AgentHookSocketServer.sendCommandResponse(
        clientFD: clientFD, ok: false, error: "Missing worktreeID for appearance.")
      return
    }
    guard let (repository, worktree) = resolveWorktree(worktreeID, in: repos) else {
      AgentHookSocketServer.sendCommandResponse(
        clientFD: clientFD, ok: false, error: "Worktree not found: \(worktreeID)")
      return
    }
    let bucket = store.repositories.sidebar.currentBucket(of: worktree.id, in: repository.id)
    let item = bucket.flatMap {
      store.repositories.sidebar.sections[repository.id]?.buckets[$0]?.items[worktree.id]
    }
    AgentHookSocketServer.sendQueryResponse(
      clientFD: clientFD,
      data: [
        WorktreeAppearanceQueryResponse.fields(
          repository: repository,
          worktree: worktree,
          item: item
        )
      ]
    )
  }

  private static func handleScriptsQuery(
    params: [String: String],
    repos: IdentifiedArrayOf<Repository>,
    clientFD: Int32,
    store: StoreOf<AppFeature>
  ) {
    guard let worktreeID = params["worktreeID"] else {
      AgentHookSocketServer.sendCommandResponse(
        clientFD: clientFD, ok: false, error: "Missing worktreeID for script list.")
      return
    }
    guard let (_, worktree) = resolveWorktree(worktreeID, in: repos) else {
      AgentHookSocketServer.sendCommandResponse(
        clientFD: clientFD, ok: false, error: "Worktree not found: \(worktreeID)")
      return
    }
    @SharedReader(.repositorySettings(worktree.repositoryRootURL, host: worktree.host)) var settings
    @SharedReader(.settingsFile) var settingsFile
    let runningIDs: Set<UUID> =
      store.repositories.sidebarItems[id: worktree.id]
      .map { Set($0.runningScripts.ids) } ?? []
    let scripts: [ScriptDefinition] = .merged(
      repo: settings.scripts,
      global: settingsFile.global.globalScripts,
    )
    let data = scripts.map { script in
      [
        "id": script.id.uuidString,
        "kind": script.kind.rawValue,
        "name": script.name,
        "displayName": script.displayName,
        "running": runningIDs.contains(script.id) ? "1" : "",
      ]
    }
    AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: data)
  }

  private static func resolveWorktree(
    _ worktreeID: String,
    in repos: IdentifiedArrayOf<Repository>
  ) -> (Repository, Worktree)? {
    let decoded = worktreeID.removingPercentEncoding ?? worktreeID
    return repos.lazy.compactMap { repo -> (Repository, Worktree)? in
      // IDs from standardizedFileURL carry a trailing slash; accept both forms.
      let worktree = repo.worktrees.first { candidate in
        candidate.id.rawValue == decoded || candidate.id.rawValue == decoded + "/"
      }
      return worktree.map { (repo, $0) }
    }.first
  }

  var body: some Scene {
    Window("Supacode", id: WindowID.main) {
      GhosttyColorSchemeSyncView(ghostty: ghostty) {
        ContentView(store: store, terminalManager: terminalManager)
          .environment(ghosttyShortcuts)
          .environment(commandKeyObserver)
          .environment(openActionIcons)
          .appChromeTextSize(store.settings.chromeTextSize)
          .background { GlobalHotkeyInstaller(monitor: globalHotkeyMonitor) }
      }
      .openSettingsOnSelection(store: store)
      .openDeeplinkReferenceOnRequest(store: store)
    }
    .handlesExternalEvents(matching: [])
    .environment(ghosttyShortcuts)
    .environment(commandKeyObserver)
    .environment(openActionIcons)
    .commands {
      WorktreeCommands(store: store)
      SidebarCommands()
      Group {
        TerminalCommands()
        TerminalTabSelectionCommands(store: store)
      }
      WindowCommands()
      CommandGroup(after: .textEditing) {
        Button("Go to Worktree") {
          guard NSApp.currentEvent?.isAutoRepeatKeyDown != true else { return }
          store.send(.commandPalette(.togglePresentInMode(.worktreeSwitcher)))
        }
        .appKeyboardShortcut(AppShortcuts.worktreeSwitcher.effective(from: store.settings.shortcutOverrides))
        .help("Switch between worktrees, sorted by most recently used")
        Button("Command Palette") {
          guard NSApp.currentEvent?.isAutoRepeatKeyDown != true else { return }
          store.send(.commandPalette(.togglePresentInMode(.commands)))
        }
        .appKeyboardShortcut(AppShortcuts.commandPalette.effective(from: store.settings.shortcutOverrides))
        .help("Command Palette")
      }
      UpdateCommands(store: store.scope(state: \.updates, action: \.updates))
      CommandGroup(replacing: .singleWindowList) {
        Button("Supacode") {
          NSApplication.shared.surfaceMainWindow()
        }
        .appKeyboardShortcut(AppShortcuts.showMainWindow.effective(from: store.settings.shortcutOverrides))
        .help("Show Main Window")
      }
      CommandGroup(replacing: .appSettings) {
        SettingsMenuButton(shortcutOverrides: store.settings.shortcutOverrides) {
          store.send(.settings(.setSelection(.general)))
        }
      }
      CommandGroup(replacing: .help) {
        Button("Submit GitHub Issue") {
          guard let url = URL(string: "https://github.com/supabitapp/supacode/issues/new") else { return }
          NSWorkspace.shared.open(url)
        }
        .help("Submit GitHub Issue")
      }
      CommandGroup(replacing: .appTermination) {
        Button("Quit Supacode") {
          store.send(.requestQuit)
        }
        .keyboardShortcut("q")
        .help("Quit Supacode (⌘Q)")
      }
    }
    Window("Settings", id: WindowID.settings) {
      SettingsView(store: store)
        .environment(ghosttyShortcuts)
        .environment(commandKeyObserver)
        .appChromeTextSize(store.settings.chromeTextSize)
        .appChromeBaseFont(store.settings.chromeTextSize)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbarColorScheme(store.settings.appearanceMode.colorScheme, for: .windowToolbar)
        .movesSettingsWindowToActiveSpace()
    }
    .handlesExternalEvents(matching: [])
    .windowToolbarStyle(.unified)
    .defaultSize(width: 800, height: 600)
    .restorationBehavior(.disabled)
    Window("Deeplink Reference", id: WindowID.deeplinkReference) {
      DeeplinkReferenceView()
        .appChromeTextSize(store.settings.chromeTextSize)
        .appChromeBaseFont(store.settings.chromeTextSize)
    }
    .handlesExternalEvents(matching: [])
    .windowToolbarStyle(.unified)
    .defaultSize(width: 720, height: 640)
    .restorationBehavior(.disabled)
    Window("CLI Reference", id: WindowID.cliReference) {
      CLIReferenceView()
        .appChromeTextSize(store.settings.chromeTextSize)
        .appChromeBaseFont(store.settings.chromeTextSize)
    }
    .handlesExternalEvents(matching: [])
    .windowToolbarStyle(.unified)
    .defaultSize(width: 720, height: 640)
    .restorationBehavior(.disabled)
    MenuBarExtra(isInserted: menuBarInserted) {
      MenuBarNotificationsMenu(store: store)
        .appChromeTextSize(store.settings.chromeTextSize)
    } label: {
      MenuBarNotificationsLabel(unreadCount: store.notificationIndicatorCount)
    }
    // `.window`, not `.menu`: a native menu item can't host the sidebar row's
    // dots, agent badges, and diff stats. The panel is styled to read like a menu.
    .menuBarExtraStyle(.window)
  }

  /// Dragging the status item out of the menu bar falls back to `.dock`, so at
  /// least one surface stays enabled.
  private var menuBarInserted: Binding<Bool> {
    Binding(
      get: { store.settings.appVisibility.showsMenuBarIcon },
      set: { newValue in
        // Ignore MenuBarExtra's scene-evaluation echo; only a real flip should persist.
        guard newValue != store.settings.appVisibility.showsMenuBarIcon else { return }
        store.send(.settings(.setAppVisibility(newValue ? .dockAndMenuBar : .dock)))
      }
    )
  }
}
