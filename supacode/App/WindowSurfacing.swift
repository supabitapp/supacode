import AppKit
import SupacodeSettingsShared

extension NSApplication {
  /// Applies the Dock/menu-bar visibility mode: `.menuBar` runs as an
  /// accessory (no Dock icon), every other mode as a regular app. Idempotent —
  /// safe to call on every settings change.
  @MainActor
  func applyActivationPolicy(for visibility: AppVisibility) {
    let policy: NSApplication.ActivationPolicy = visibility.hidesDockIcon ? .accessory : .regular
    guard activationPolicy() != policy else { return }
    setActivationPolicy(policy)
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
    let candidates = windows.filter { !($0 is NSPanel) }
    if let window = candidates.first(where: { $0.identifier?.rawValue != WindowID.settings }) {
      return window
    }
    return candidates.first
  }
}
