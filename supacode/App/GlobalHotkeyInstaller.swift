import AppKit
import SwiftUI

// Installs the toggle sink from the main window's scene, where `openWindow` is
// reachable, and never clears it so the chord can reopen a closed window.
struct GlobalHotkeyInstaller: View {
  let monitor: GlobalHotkeyMonitor
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .onAppear {
        monitor.onFired = {
          let app = NSApplication.shared
          let hasVisibleMain =
            app.mainWindowCandidate().map {
              $0.isVisible && !$0.isMiniaturized && $0.isOnActiveSpace
            } ?? false
          switch GlobalHotkeyToggle.resolve(isActive: app.isActive, hasVisibleMain: hasVisibleMain) {
          case .hide:
            app.hide(nil)
          case .show:
            openWindow(id: WindowID.main)
            app.surfaceMainWindow()
          }
        }
      }
  }
}
