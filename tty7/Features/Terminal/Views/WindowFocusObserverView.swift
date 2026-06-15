import AppKit
import SwiftUI

struct WindowActivityState: Equatable {
  let isKeyWindow: Bool
  let isVisible: Bool

  static let inactive = Self(isKeyWindow: false, isVisible: false)
}

struct WindowFocusObserverView: NSViewRepresentable {
  let onWindowActivityChanged: (WindowActivityState) -> Void

  func makeNSView(context: Context) -> WindowFocusObserverNSView {
    let view = WindowFocusObserverNSView()
    view.onWindowActivityChanged = onWindowActivityChanged
    return view
  }

  func updateNSView(_ nsView: WindowFocusObserverNSView, context: Context) {
    nsView.onWindowActivityChanged = onWindowActivityChanged
  }
}

final class WindowFocusObserverNSView: NSView {
  var onWindowActivityChanged: (WindowActivityState) -> Void = { _ in }
  private var observers: [NSObjectProtocol] = []
  private weak var observedWindow: NSWindow?
  private var lastEmittedActivity: WindowActivityState?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateObservers()
  }

  private var activityState: WindowActivityState {
    guard let window else { return .inactive }
    return WindowActivityState(
      isKeyWindow: window.isKeyWindow,
      isVisible: window.occlusionState.contains(.visible)
    )
  }

  private func updateObservers() {
    if observedWindow === window {
      emitActivityIfNeeded()
      return
    }
    clearObservers()
    observedWindow = window
    guard let window else {
      emitActivityIfNeeded(force: true)
      return
    }
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.emitActivityIfNeeded()
        }
      })
    observers.append(
      center.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.emitActivityIfNeeded()
        }
      })
    observers.append(
      center.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.emitActivityIfNeeded()
        }
      })
    emitActivityIfNeeded(force: true)
  }

  private func emitActivityIfNeeded(force: Bool = false) {
    let activity = activityState
    if !force, activity == lastEmittedActivity {
      return
    }
    lastEmittedActivity = activity
    onWindowActivityChanged(activity)
  }

  private func clearObservers() {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
    }
    observers.removeAll()
  }

  isolated deinit {
    clearObservers()
  }
}
