import AppKit
import SupacodeSettingsShared

private let visibilityLogger = SupaLogger("AppVisibility")

extension NSApplication {
  /// Applies the Dock/menu-bar visibility mode: `.menuBar` runs as an accessory
  /// (no Dock icon), every other mode as a regular app. Returns false when
  /// AppKit refuses the switch.
  @MainActor
  @discardableResult
  func applyActivationPolicy(for visibility: AppVisibility) -> Bool {
    let policy: NSApplication.ActivationPolicy = visibility.hidesDockIcon ? .accessory : .regular
    guard activationPolicy() != policy else { return true }
    if setActivationPolicy(policy) { return true }
    // AppKit refuses `.accessory` -> `.regular` while the app is inactive, so
    // retry once activated. Only that direction: force-activating to *hide* the
    // Dock icon would pop the app to the front for a quieting action.
    guard policy == .regular else {
      visibilityLogger.error("setActivationPolicy(.accessory) refused; app stays regular.")
      return false
    }
    activate()
    guard setActivationPolicy(policy) else {
      visibilityLogger.error("setActivationPolicy(.regular) refused; app stays accessory.")
      return false
    }
    return true
  }

  /// Brings the main window forward, deminiaturizing if needed.
  ///
  /// Falls back to any non-`NSPanel`, non-settings window so a stale
  /// `NSColorPanel`/`NSFontPanel` cannot shadow the real main window.
  /// Returns `true` when a window was surfaced.
  @MainActor
  @discardableResult
  func surfaceMainWindow() -> Bool {
    guard let window = mainWindowCandidate() else {
      activate()
      return false
    }
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
    activate()
    return true
  }

  private func mainWindowCandidate() -> NSWindow? {
    if let window = windows.first(where: { $0.identifier?.rawValue == WindowID.main }) {
      return window
    }
    let candidates = windows.filter(\.isSurfaceableAppWindow)
    if let window = candidates.first(where: { $0.identifier?.rawValue != WindowID.settings }) {
      return window
    }
    return candidates.first
  }
}

extension NSWindow {
  /// A real app window the user can be sent to. Excludes `NSPanel` (the shared
  /// color / font panels) and anything that can't take main status, notably the
  /// status item's window, which would otherwise pass for a visible main window
  /// once the menu bar extra is inserted.
  var isSurfaceableAppWindow: Bool {
    canBecomeMain && !(self is NSPanel)
  }
}
