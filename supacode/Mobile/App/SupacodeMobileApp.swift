import ComposableArchitecture
import GhosttyKit
import SwiftUI
import UIKit

@main
@MainActor
struct SupacodeMobileApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var terminalManager: MobileTerminalSessionManager
  @State private var store: StoreOf<MobileAppFeature>
  @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

  @MainActor init() {
    if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("ghostty") {
      setenv("GHOSTTY_RESOURCES_DIR", resourceURL.path, 1)
    }
    if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
      preconditionFailure("ghostty_init failed")
    }

    let terminalManager = MobileTerminalSessionManager()
    _terminalManager = State(initialValue: terminalManager)

    let appStore = Store(initialState: MobileAppFeature.State()) {
      MobileAppFeature()
    } withDependencies: { values in
      values.mobileTerminalClient = MobileTerminalClient(
        send: { command in
          terminalManager.handleCommand(command)
        },
        events: {
          terminalManager.eventStream()
        }
      )
    }
    _store = State(initialValue: appStore)
  }

  var body: some Scene {
    WindowGroup {
      MobileContentView(store: store, terminalManager: terminalManager)
        .preferredColorScheme(.dark)
        .mobileKeyboardShortcuts(store: store)
        .task {
          store.send(.task)
        }
    }
    .onChange(of: scenePhase) { _, phase in
      store.send(.scenePhaseChanged(phase))
      switch phase {
      case .active:
        endBackgroundTask()
      case .background:
        beginBackgroundTask()
      case .inactive:
        break
      @unknown default:
        break
      }
    }
  }

  private func beginBackgroundTask() {
    guard backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SupacodeTerminalSession") {
      endBackgroundTask()
    }
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }
}
