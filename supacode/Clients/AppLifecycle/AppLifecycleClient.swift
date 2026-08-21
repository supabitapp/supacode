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
  /// Registers the visibility-toggle chord (nil clears it); false when Carbon
  /// refuses. The app injects the live impl over its `GlobalHotkeyMonitor`.
  var updateGlobalHotkey: @MainActor @Sendable (AppShortcutOverride?) -> Bool
}

extension AppLifecycleClient: DependencyKey {
  static let liveValue = AppLifecycleClient(
    terminate: { NSApplication.shared.terminate(nil) },
    applyVisibility: { NSApplication.shared.applyActivationPolicy(for: $0) },
    surfaceMainWindow: { NSApplication.shared.surfaceMainWindow() },
    // Overridden at store creation with the app-owned monitor. The default only
    // fires if that wiring is missing, so it fails loudly rather than silently.
    updateGlobalHotkey: { _ in
      SupaLogger("GlobalHotkey").error("updateGlobalHotkey called without a wired monitor.")
      return false
    }
  )

  static let testValue = AppLifecycleClient(
    terminate: unimplemented("AppLifecycleClient.terminate"),
    applyVisibility: unimplemented("AppLifecycleClient.applyVisibility", placeholder: true),
    surfaceMainWindow: unimplemented("AppLifecycleClient.surfaceMainWindow", placeholder: true),
    updateGlobalHotkey: unimplemented("AppLifecycleClient.updateGlobalHotkey", placeholder: true)
  )
}

extension DependencyValues {
  var appLifecycleClient: AppLifecycleClient {
    get { self[AppLifecycleClient.self] }
    set { self[AppLifecycleClient.self] = newValue }
  }
}
