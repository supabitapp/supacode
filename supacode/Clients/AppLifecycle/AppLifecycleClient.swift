import AppKit
import ComposableArchitecture
import SupacodeSettingsShared

struct AppLifecycleClient {
  var terminate: @MainActor @Sendable () -> Void
  /// Applies the Dock/menu-bar visibility mode. Returns false when AppKit
  /// refuses the switch, which would otherwise leave the app with no surface.
  var applyVisibility: @MainActor @Sendable (AppVisibility) -> Bool
  /// Brings the main window forward. Returns false when there is no window to surface.
  var surfaceMainWindow: @MainActor @Sendable () -> Bool
}

extension AppLifecycleClient: DependencyKey {
  static let liveValue = AppLifecycleClient(
    terminate: { NSApplication.shared.terminate(nil) },
    applyVisibility: { NSApplication.shared.applyActivationPolicy(for: $0) },
    surfaceMainWindow: { NSApplication.shared.surfaceMainWindow() }
  )

  static let testValue = AppLifecycleClient(
    terminate: unimplemented("AppLifecycleClient.terminate"),
    applyVisibility: unimplemented("AppLifecycleClient.applyVisibility", placeholder: true),
    surfaceMainWindow: unimplemented("AppLifecycleClient.surfaceMainWindow", placeholder: true)
  )
}

extension DependencyValues {
  var appLifecycleClient: AppLifecycleClient {
    get { self[AppLifecycleClient.self] }
    set { self[AppLifecycleClient.self] = newValue }
  }
}
