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
  static let argv: [UnsafeMutablePointer<CChar>?] = {
    @Shared(.settingsFile) var settingsFile
    let overrides = settingsFile.global.shortcutOverrides
    var args: [UnsafeMutablePointer<CChar>?] = []
    let executable = CommandLine.arguments.first ?? "supacode"
    args.append(strdup(executable))
    for keybindArgument in AppShortcuts.ghosttyCLIKeybindArguments(from: overrides) {
      args.append(strdup(keybindArgument))
    }
    args.append(nil)
    return args
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
  private var bufferedDeeplinkURLs: [URL] = []

  func applicationWillTerminate(_ notification: Notification) {
    // Drop the queued debounce timers; an already-started async flush has no
    // cancellation checkpoint and still completes, but the writer's lock plus the
    // atomic temp+rename keep this terminal write from tearing. The on-quit save
    // embeds agent records so badges survive relaunch (agents only emit
    // session_start once per process lifetime), and a second concurrent instance
    // overwriting the file is an accepted dev-only last-writer-wins window.
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
  @State private var openActionIcons = OpenActionIconStore()
  @State private var store: StoreOf<AppFeature>

  @MainActor init() {
    NSWindow.allowsAutomaticWindowTabbing = false
    UserDefaults.standard.set(200, forKey: "NSInitialToolTipDelay")
    // Fold the six legacy sidebar-state sources into `sidebar.json`
    // before any @Shared binding observes them:
    //   1. `@Shared(.appStorage("sidebarCollapsedRepositoryIDs"))`.
    //   2. `@Shared(.appStorage("repositoryOrderIDs"))`.
    //   3. `@Shared(.appStorage("worktreeOrderByRepository"))`.
    //   4. `@Shared(.appStorage("lastFocusedWorktreeID"))`.
    //   5. `@Shared(.appStorage("archivedWorktreeDates"))` (the
    //      legacy key; the client that wrapped it is being retired
    //      in a parallel task).
    //   6. `settingsFile.pinnedWorktreeIDs` (the `SettingsFile`
    //      slice).
    // Idempotent — gates on whether `sidebar.json` already exists
    // AND carries `schemaVersion >= 1` — so the downgrade →
    // re-upgrade path can't double-migrate, while a prior
    // half-finished migration that left a `schemaVersion == 0` file
    // still gets retried.
    // Snapshot settings.json + sidebar.json before any migration or @Shared hydration
    // can rewrite them, so a botched migration or downgrade is recoverable by hand.
    SidebarPersistenceMigrator.backupBeforeRemoteIdentityMigration()
    // Capture the retired `global.remoteRepositories` before any migration can
    // re-encode settings and drop the field. An unreadable settings.json skips
    // both passes this launch (a save would strip it first); they retry next launch.
    let capturedLegacyRemotes = SidebarPersistenceMigrator.captureLegacyRemoteRoots()
    if capturedLegacyRemotes != .unreadable {
      SidebarPersistenceMigrator.migrateIfNeeded()
      SidebarPersistenceMigrator.migrateRemoteIdentityIfNeeded(capturedLegacy: capturedLegacyRemotes)
    }
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
    let worktreeInfoWatcher = WorktreeInfoWatcherManager()
    _worktreeInfoWatcher = State(initialValue: worktreeInfoWatcher)
    let keyObserver = CommandKeyObserver()
    _commandKeyObserver = State(initialValue: keyObserver)
    let appStore = Self.makeStore(
      initialSettings: initialSettings,
      terminalManager: terminalManager,
      worktreeInfoWatcher: worktreeInfoWatcher
    )
    _store = State(initialValue: appStore)
    appDelegate.appStore = appStore
    appDelegate.terminalManager = terminalManager
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
    terminalManager.saveLayoutSnapshot = { worktreeID, snapshot in
      @Shared(.layouts) var layouts: [String: TerminalLayoutSnapshot] = [:]
      $layouts.withLock { dict in
        if let snapshot {
          dict[worktreeID.rawValue] = snapshot
        } else {
          dict.removeValue(forKey: worktreeID.rawValue)
        }
      }
    }
    terminalManager.loadLayoutSnapshot = { worktreeID in
      @SharedReader(.layouts) var layouts: [String: TerminalLayoutSnapshot] = [:]
      return layouts[worktreeID.rawValue]
    }
    return terminalManager
  }

  @MainActor
  private static func makeStore(
    initialSettings: GlobalSettings,
    terminalManager: WorktreeTerminalManager,
    worktreeInfoWatcher: WorktreeInfoWatcherManager
  ) -> StoreOf<AppFeature> {
    Store(initialState: AppFeature.State(settings: SettingsFeature.State(settings: initialSettings))) {
      AppFeature()
        .logActions()
    } withDependencies: { values in
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
        tabID: { worktreeID, surfaceID in
          terminalManager.tabID(forWorktreeID: worktreeID, surfaceID: surfaceID)
        },
        selectedTabID: { worktreeID in
          terminalManager.stateIfExists(for: worktreeID)?.tabManager.selectedTabId
        },
        selectedSurfaceID: { worktreeID in
          guard let state = terminalManager.stateIfExists(for: worktreeID),
            let tabID = state.tabManager.selectedTabId
          else { return nil }
          return state.activeSurfaceID(for: tabID)
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
        TerminalCommands(ghosttyShortcuts: ghosttyShortcuts)
        TerminalTabSelectionCommands(store: store)
      }
      WindowCommands(ghosttyShortcuts: ghosttyShortcuts)
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
    }
    .handlesExternalEvents(matching: [])
    .windowToolbarStyle(.unified)
    .defaultSize(width: 720, height: 640)
    .restorationBehavior(.disabled)
    Window("CLI Reference", id: WindowID.cliReference) {
      CLIReferenceView()
    }
    .handlesExternalEvents(matching: [])
    .windowToolbarStyle(.unified)
    .defaultSize(width: 720, height: 640)
    .restorationBehavior(.disabled)
    MenuBarExtra(isInserted: menuBarInserted) {
      MenuBarNotificationsMenu(store: store)
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
