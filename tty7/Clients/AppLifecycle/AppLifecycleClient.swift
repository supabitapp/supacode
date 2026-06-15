import AppKit
import ComposableArchitecture

struct AppLifecycleClient {
  var terminate: @MainActor @Sendable () -> Void
}

extension AppLifecycleClient: DependencyKey {
  static let liveValue = AppLifecycleClient(
    terminate: { NSApplication.shared.terminate(nil) }
  )

  static let testValue = AppLifecycleClient(
    terminate: unimplemented("AppLifecycleClient.terminate")
  )
}

extension DependencyValues {
  var appLifecycleClient: AppLifecycleClient {
    get { self[AppLifecycleClient.self] }
    set { self[AppLifecycleClient.self] = newValue }
  }
}
