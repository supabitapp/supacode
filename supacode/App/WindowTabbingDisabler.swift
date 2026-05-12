import AppKit
import SwiftUI

struct WindowTabbingDisabler: NSViewRepresentable {
  func makeNSView(context: Context) -> WindowTabbingView {
    WindowTabbingView()
  }

  func updateNSView(_ nsView: WindowTabbingView, context: Context) {
    nsView.disallowTabbing()
  }
}

final class WindowTabbingView: NSView, NSWindowDelegate {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    disallowTabbing()
  }

  func disallowTabbing() {
    guard let window else { return }
    window.tabbingMode = .disallowed
    window.identifier = NSUserInterfaceItemIdentifier(WindowID.main)
    // Persist and restore the window frame (position + size) across launches,
    // including when the window is on a secondary display. macOS handles the
    // save/restore automatically once an autosave name is set.
    if window.frameAutosaveName.rawValue != WindowID.main {
      window.setFrameAutosaveName(WindowID.main)
    }
    if window.delegate !== self {
      window.delegate = self
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    return false
  }
}
