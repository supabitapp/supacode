import AppKit
import SwiftUI

// SwiftUI's `Window` scene never sets `collectionBehavior`, so a reopened
// Settings window snaps back to the Space it was last shown on. Pin it to the
// active Space and let it float over a full-screen main window.
struct SettingsWindowSpaceBehavior: NSViewRepresentable {
  func makeNSView(context: Context) -> SettingsWindowSpaceBehaviorNSView {
    SettingsWindowSpaceBehaviorNSView()
  }

  func updateNSView(_ nsView: SettingsWindowSpaceBehaviorNSView, context: Context) {}
}

@MainActor
final class SettingsWindowSpaceBehaviorNSView: NSView {
  private var keyObserver: NSObjectProtocol?

  isolated deinit {
    clearObserver()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    clearObserver()
    guard let window else { return }
    // Re-assert on key so a SwiftUI reconfigure can't clobber the behavior.
    keyObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.apply() }
    }
    apply()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  private func apply() {
    guard let window else { return }
    var behavior = window.collectionBehavior
    behavior.remove(.canJoinAllSpaces)
    behavior.remove(.fullScreenPrimary)
    behavior.insert(.moveToActiveSpace)
    behavior.insert(.fullScreenAuxiliary)
    window.collectionBehavior = behavior
  }

  private func clearObserver() {
    guard let keyObserver else { return }
    NotificationCenter.default.removeObserver(keyObserver)
    self.keyObserver = nil
  }
}

extension View {
  /// Keeps the Settings window on the active Space instead of switching back to the Space it was last shown on.
  func movesSettingsWindowToActiveSpace() -> some View {
    background(SettingsWindowSpaceBehavior())
  }
}
