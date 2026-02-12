import AppKit
import SwiftUI

struct WindowFocusObserverView: NSViewRepresentable {
  let onWindowKeyChanged: (Bool) -> Void

  func makeNSView(context: Context) -> WindowFocusObserverNSView {
    let view = WindowFocusObserverNSView()
    view.onWindowKeyChanged = onWindowKeyChanged
    return view
  }

  func updateNSView(_ nsView: WindowFocusObserverNSView, context: Context) {
    nsView.onWindowKeyChanged = onWindowKeyChanged
    nsView.notifyCurrentState()
  }
}

final class WindowFocusObserverNSView: NSView {
  var onWindowKeyChanged: (Bool) -> Void = { _ in }
  private var observers: [NSObjectProtocol] = []
  private weak var observedWindow: NSWindow?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateObservers()
  }

  func notifyCurrentState() {
    onWindowKeyChanged(windowIsEffectivelyKey)
  }

  private var windowIsEffectivelyKey: Bool {
    guard let window else { return false }
    return window.isKeyWindow && window.occlusionState.contains(.visible)
  }

  private func updateObservers() {
    if observedWindow === window {
      notifyCurrentState()
      return
    }
    clearObservers()
    observedWindow = window
    guard let window else {
      onWindowKeyChanged(false)
      return
    }
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        self.onWindowKeyChanged(self.windowIsEffectivelyKey)
      })
    observers.append(
      center.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        self?.onWindowKeyChanged(false)
      })
    observers.append(
      center.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        self.onWindowKeyChanged(self.windowIsEffectivelyKey)
      })
    onWindowKeyChanged(windowIsEffectivelyKey)
  }

  private func clearObservers() {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
    }
    observers.removeAll()
  }

  deinit {
    clearObservers()
  }
}
