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
import PostHog
import Sentry
import Sharing
import SwiftUI

private enum GhosttyCLI {
  static let argv: [UnsafeMutablePointer<CChar>?] = {
    var args: [UnsafeMutablePointer<CChar>?] = []
    let executable = CommandLine.arguments.first ?? "supacode"
    args.append(strdup(executable))
    for shortcut in AppShortcuts.all {
      args.append(strdup("--keybind=\(shortcut.ghosttyKeybind)=unbind"))
    }
    args.append(nil)
    return args
  }()
}

@MainActor
final class SupacodeAppDelegate: NSObject, NSApplicationDelegate {
  var appStore: StoreOf<AppFeature>?

  func applicationDidFinishLaunching(_ notification: Notification) {
    appStore?.send(.appLaunched)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if flag { return true }
    guard let window = mainWindow(from: sender) else { return true }
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
    sender.activate()
    return false
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  private func mainWindow(from sender: NSApplication) -> NSWindow? {
    if let window = sender.windows.first(where: { $0.identifier?.rawValue == "main" }) {
      return window
    }
    if let window = sender.windows.first(where: { $0.identifier?.rawValue != "settings" }) {
      return window
    }
    return sender.windows.first
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
    @Shared(.settingsFile) var settingsFile
    let initialSettings = settingsFile.global
    #if !DEBUG
      if initialSettings.crashReportsEnabled {
        SentrySDK.start { options in
          options.dsn = "__SENTRY_DSN__"
          options.tracesSampleRate = 1.0
          options.enableAppHangTracking = false
        }
      }
      if initialSettings.analyticsEnabled {
        let posthogAPIKey = "__POSTHOG_API_KEY__"
        let posthogHost = "__POSTHOG_HOST__"
        let config = PostHogConfig(apiKey: posthogAPIKey, host: posthogHost)
        config.enableSwizzling = false
        PostHogSDK.shared.setup(config)
        if let hardwareUUID = HardwareInfo.uuid {
          PostHogSDK.shared.identify(hardwareUUID)
        }
      }
    #endif
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
    let terminalManager = WorktreeTerminalManager(runtime: runtime)
    _terminalManager = State(initialValue: terminalManager)
    let worktreeInfoWatcher = WorktreeInfoWatcherManager()
    _worktreeInfoWatcher = State(initialValue: worktreeInfoWatcher)
    let keyObserver = CommandKeyObserver()
    _commandKeyObserver = State(initialValue: keyObserver)
    let appStore = Store(
      initialState: AppFeature.State(settings: SettingsFeature.State(settings: initialSettings))
    ) {
      AppFeature()
        .logActions()
    } withDependencies: { values in
      values.terminalClient = TerminalClient(
        send: { command in
          terminalManager.handleCommand(command)
        },
        events: {
          terminalManager.eventStream()
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
    }
    _store = State(initialValue: appStore)
    appDelegate.appStore = appStore
    SettingsWindowManager.shared.configure(
      store: appStore,
      ghosttyShortcuts: shortcuts,
      commandKeyObserver: keyObserver
    )
  }

  var body: some Scene {
    Window("Supacode", id: "main") {
      GhosttyColorSchemeSyncView(ghostty: ghostty) {
        ContentView(store: store, terminalManager: terminalManager)
          .environment(ghosttyShortcuts)
          .environment(commandKeyObserver)
      }
      .preferredColorScheme(store.settings.appearanceMode.colorScheme)
    }
    .environment(ghosttyShortcuts)
    .environment(commandKeyObserver)
    .commands {
      WorktreeCommands(store: store)
      SidebarCommands()
      TerminalCommands(ghosttyShortcuts: ghosttyShortcuts)
      CommandGroup(after: .textEditing) {
        Button("Command Palette") {
          store.send(.commandPalette(.togglePresented))
        }
        .keyboardShortcut("p", modifiers: .command)
        .help("Command Palette (⌘P)")
      }
      UpdateCommands(store: store.scope(state: \.updates, action: \.updates))
      CommandGroup(replacing: .windowArrangement) {
        Button("Minimize") {
          NSApp.keyWindow?.miniaturize(nil)
        }
        .keyboardShortcut("m")
        .help("Minimize (⌘M)")
        Button("Zoom") {
          NSApp.keyWindow?.zoom(nil)
        }
        .help("Zoom (no shortcut)")
      }
      CommandGroup(replacing: .appSettings) {
        Button("Settings...") {
          SettingsWindowManager.shared.show()
        }
        .keyboardShortcut(
          AppShortcuts.openSettings.keyEquivalent,
          modifiers: AppShortcuts.openSettings.modifiers
        )
      }
      CommandGroup(replacing: .appTermination) {
        Button("Quit Supacode") {
          store.send(.requestQuit)
        }
        .keyboardShortcut("q")
        .help("Quit Supacode (⌘Q)")
      }
    }
  }
}
