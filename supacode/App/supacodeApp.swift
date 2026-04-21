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
    terminalManager?.saveAllLayoutSnapshots()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Disable press-and-hold accent menu so that key repeat works in the terminal.
    UserDefaults.standard.register(defaults: [
      "ApplePressAndHoldEnabled": false
    ])
    appStore?.send(.appLaunched)
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    let app = NSApplication.shared
    guard !app.windows.contains(where: \.isVisible) else { return }
    _ = showMainWindow(from: app)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if flag { return true }
    return showMainWindow(from: sender) ? false : true
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

  private func mainWindow(from sender: NSApplication) -> NSWindow? {
    if let window = sender.windows.first(where: { $0.identifier?.rawValue == WindowID.main }) {
      return window
    }
    if let window = sender.windows.first(where: { $0.identifier?.rawValue != WindowID.settings }) {
      return window
    }
    return sender.windows.first
  }

  private func showMainWindow(from sender: NSApplication) -> Bool {
    guard let window = mainWindow(from: sender) else { return false }
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    sender.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    return true
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
    SidebarPersistenceMigrator.migrateIfNeeded()
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
    Self.configureSocketHandlers(terminalManager: terminalManager, store: appStore)
  }

  @MainActor
  private static func makeTerminalManager(runtime: GhosttyRuntime) -> WorktreeTerminalManager {
    let terminalManager = WorktreeTerminalManager(runtime: runtime)
    terminalManager.saveLayoutSnapshot = { worktreeID, snapshot in
      @Shared(.layouts) var layouts: [String: TerminalLayoutSnapshot] = [:]
      $layouts.withLock { dict in
        if let snapshot {
          dict[worktreeID] = snapshot
        } else {
          dict.removeValue(forKey: worktreeID)
        }
      }
    }
    terminalManager.loadLayoutSnapshot = { worktreeID in
      @SharedReader(.settingsFile) var settingsFile
      guard settingsFile.global.restoreTerminalLayoutEnabled else { return nil }
      @SharedReader(.layouts) var layouts: [String: TerminalLayoutSnapshot] = [:]
      return layouts[worktreeID]
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
        surfaceExists: { worktreeID, tabID, surfaceID in
          terminalManager.surfaceExists(worktreeID: worktreeID, tabID: tabID, surfaceID: surfaceID)
        },
        surfaceExistsInWorktree: { worktreeID, surfaceID in
          terminalManager.surfaceExistsInWorktree(worktreeID: worktreeID, surfaceID: surfaceID)
        },
        tabID: { worktreeID, surfaceID in
          terminalManager.tabID(forWorktreeID: worktreeID, surfaceID: surfaceID)
        },
        latestUnreadNotification: {
          terminalManager.latestUnreadNotificationLocation()
        },
        markNotificationRead: { worktreeID, notificationID in
          terminalManager.markNotificationRead(worktreeID: worktreeID, notificationID: notificationID)
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
    let pctSet = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "/"))

    switch resource {
    case "repos":
      let data = repos.map {
        ["id": $0.id.addingPercentEncoding(withAllowedCharacters: pctSet) ?? $0.id]
      }
      AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: data)
    case "worktrees":
      let data = repos.flatMap { repo in
        repo.worktrees.map { worktree in
          let encodedID = worktree.id.addingPercentEncoding(withAllowedCharacters: pctSet) ?? worktree.id
          var entry = ["id": encodedID]
          if worktree.id == selectedWorktreeID { entry["focused"] = "1" }
          return entry
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
        let worktreeExists = repos.contains { $0.worktrees.contains { $0.id == decoded } }
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
    case "scripts":
      guard let worktreeID = params["worktreeID"] else {
        AgentHookSocketServer.sendCommandResponse(
          clientFD: clientFD, ok: false, error: "Missing worktreeID for script list.")
        return
      }
      let decoded = worktreeID.removingPercentEncoding ?? worktreeID
      // Worktree IDs from standardizedFileURL include a trailing slash, so
      // accept both forms — matching the deeplink reducer's resolveWorktreeID.
      let allWorktrees = repos.flatMap(\.worktrees)
      let worktree =
        allWorktrees.first(where: { $0.id == decoded })
        ?? allWorktrees.first(where: { $0.id == decoded + "/" })
      guard let worktree else {
        AgentHookSocketServer.sendCommandResponse(
          clientFD: clientFD, ok: false, error: "Worktree not found: \(worktreeID)")
        return
      }
      @SharedReader(.repositorySettings(worktree.repositoryRootURL)) var settings
      let runningIDs = store.repositories.runningScriptsByWorktreeID[worktree.id] ?? [:]
      let data = settings.scripts.map { script in
        [
          "id": script.id.uuidString,
          "kind": script.kind.rawValue,
          "name": script.name,
          "displayName": script.displayName,
          "running": runningIDs[script.id] != nil ? "1" : "",
        ]
      }
      AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: data)
    default:
      AgentHookSocketServer.sendCommandResponse(
        clientFD: clientFD, ok: false, error: "Unknown resource: \(resource)")
    }
  }

  var body: some Scene {
    Window("Supacode", id: WindowID.main) {
      GhosttyColorSchemeSyncView(ghostty: ghostty) {
        ContentView(store: store, terminalManager: terminalManager)
          .environment(ghosttyShortcuts)
          .environment(commandKeyObserver)
      }
      .openSettingsOnSelection(store: store)
      .openDeeplinkReferenceOnRequest(store: store)
    }
    .handlesExternalEvents(matching: [])
    .environment(ghosttyShortcuts)
    .environment(commandKeyObserver)
    .commands {
      WorktreeCommands(store: store)
      SidebarCommands()
      TerminalCommands(ghosttyShortcuts: ghosttyShortcuts)
      WindowCommands(ghosttyShortcuts: ghosttyShortcuts)
      CommandGroup(after: .textEditing) {
        let cmdPalette = AppShortcuts.commandPalette.effective(from: store.settings.shortcutOverrides)
        Button("Command Palette") {
          store.send(.commandPalette(.togglePresented))
        }
        .appKeyboardShortcut(cmdPalette)
        .help("Command Palette (\(cmdPalette?.display ?? "none"))")
      }
      UpdateCommands(store: store.scope(state: \.updates, action: \.updates))
      Group {
        CommandGroup(replacing: .windowList) {}
        CommandGroup(replacing: .singleWindowList) {
          Button("Supacode") {
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == WindowID.main }) {
              window.makeKeyAndOrderFront(nil)
              NSApp.activate(ignoringOtherApps: true)
            }
          }
          .keyboardShortcut("0")
          .help("Show main window (⌘0)")
        }
      }
      CommandGroup(replacing: .appSettings) {
        SettingsMenuButton(shortcutOverrides: store.settings.shortcutOverrides) {
          store.send(.settings(.setSelection(.general)))
        }
      }
      CommandGroup(replacing: .help) {
        DeeplinkReferenceMenuButton()
        Divider()
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
  }
}
