import AppKit
import SwiftUI

struct WindowActivityState: Equatable {
  let isKeyWindow: Bool
  let isVisible: Bool

  static let inactive = Self(isKeyWindow: false, isVisible: false)
}

/// Fresh reads of the observed window's activity, so consumers never resolve
/// against `NSApp.keyWindow` (which can be another window, e.g. the palette).
/// Wired by exactly one `WindowFocusObserverView`.
@MainActor
final class WindowActivityReader {
  fileprivate weak var view: WindowFocusObserverNSView?

  var current: WindowActivityState? { view?.currentActivity }
}

struct WindowFocusObserverView: NSViewRepresentable {
  var reader: WindowActivityReader?
  let onWindowActivityChanged: (WindowActivityState) -> Void

  func makeNSView(context: Context) -> WindowFocusObserverNSView {
    let view = WindowFocusObserverNSView()
    view.onWindowActivityChanged = onWindowActivityChanged
    reader?.view = view
    return view
  }

  func updateNSView(_ nsView: WindowFocusObserverNSView, context: Context) {
    nsView.onWindowActivityChanged = onWindowActivityChanged
    reader?.view = nsView
  }
}

final class WindowFocusObserverNSView: NSView {
  var onWindowActivityChanged: (WindowActivityState) -> Void = { _ in }
  private var observers: [NSObjectProtocol] = []
  private var appActivationObserver: NSObjectProtocol?
  private weak var observedWindow: NSWindow?
  private var lastEmittedActivity: WindowActivityState?

  /// Fresh pull-based read; nil while detached from a window (unknown), unlike
  /// the push path's deliberate `.inactive` emit for a windowless observer.
  var currentActivity: WindowActivityState? {
    window == nil ? nil : activityState
  }

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
    // A stale not-visible cache must not outlive an app activation; force a
    // fresh emit past the dedupe so re-activation always heals (#757).
    if appActivationObserver == nil {
      appActivationObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.emitActivityIfNeeded(force: true)
        }
      }
    }
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
    for name in [
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didChangeOcclusionStateNotification,
    ] {
      observers.append(
        center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          Task { @MainActor [weak self] in
            self?.emitActivityIfNeeded()
          }
        })
    }
    emitActivityIfNeeded(force: true)
  }

  private func emitActivityIfNeeded(force: Bool = false) {
    let activity = activityState
    guard force || activity != lastEmittedActivity else { return }
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
    if let appActivationObserver {
      NotificationCenter.default.removeObserver(appActivationObserver)
    }
  }
}
