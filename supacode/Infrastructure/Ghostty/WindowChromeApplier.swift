import AppKit
import GhosttyKit
import SwiftUI

struct WindowAppearanceState: Equatable {
  let opacity: Double
  let isFullScreen: Bool
  let isOpaqueOverride: Bool
  let backgroundColorKey: String
}

@MainActor
enum WindowChromeApplier {
  // Each observer site owns its own `lastApplied` so they don't fight.
  static func apply(
    window: NSWindow,
    runtime: GhosttyRuntime,
    lastApplied: inout WindowAppearanceState?
  ) {
    guard window.isVisible else { return }
    let opacity = runtime.backgroundOpacity()
    let tintColor = runtime.windowTintColor()
    let next = WindowAppearanceState(
      opacity: opacity,
      isFullScreen: window.styleMask.contains(.fullScreen),
      isOpaqueOverride: runtime.isBackgroundOpaque,
      backgroundColorKey: Self.colorKey(tintColor)
    )
    if next == lastApplied {
      return
    }
    lastApplied = next
    if !next.isFullScreen, opacity < 1, !next.isOpaqueOverride {
      window.isOpaque = false
      window.titlebarAppearsTransparent = true
      window.backgroundColor = tintColor.withAlphaComponent(opacity)
      if let app = runtime.app {
        ghostty_set_window_background_blur(
          app,
          Unmanaged.passUnretained(window).toOpaque()
        )
      }
      return
    }
    window.isOpaque = true
    window.titlebarAppearsTransparent = !next.isFullScreen
    window.backgroundColor = tintColor
  }

  // Stable per-color key for the dedupe (NSColor equality is color-space fragile).
  private static func colorKey(_ color: NSColor) -> String {
    guard let srgb = color.usingColorSpace(.sRGB) else { return "?" }
    return "\(Int(srgb.redComponent * 255)),\(Int(srgb.greenComponent * 255)),\(Int(srgb.blueComponent * 255))"
  }

  // The focused terminal's contrast drives the whole window's NSAppearance, so
  // the sidebar and chrome (toolbar text included) adopt light/dark to match.
  // Kept separate from `apply` and driven only by terminal-appearance changes
  // (focus / OSC 11 / config), never window key/occlusion/alert events: those
  // would re-assign the same appearance and flash the window.
  static func applyWindowAppearance(window: NSWindow, runtime: GhosttyRuntime) {
    let name: NSAppearance.Name = runtime.windowTintColor().isLightColor ? .aqua : .darkAqua
    guard window.appearance?.name != name else { return }
    window.appearance = NSAppearance(named: name)
  }
}

// Mounted at the ContentView root so window background re-applies on
// appearance / fullscreen / config changes even when no Ghostty surface is
// currently displayed (Empty / Loading / Archived / Multi-select states).
struct WindowChromeObserver: NSViewRepresentable {
  let runtime: GhosttyRuntime

  func makeNSView(context: Context) -> WindowChromeObserverNSView {
    WindowChromeObserverNSView(runtime: runtime)
  }

  func updateNSView(_ nsView: WindowChromeObserverNSView, context: Context) {}
}

@MainActor
final class WindowChromeObserverNSView: NSView {
  private let runtime: GhosttyRuntime
  private var lastApplied: WindowAppearanceState?
  // `nonisolated(unsafe)` so `deinit` (Swift 6 nonisolated by default for
  // @MainActor classes) can release the tokens; NotificationCenter is itself
  // thread-safe, and only main-actor methods otherwise mutate the array.
  private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

  init(runtime: GhosttyRuntime) {
    self.runtime = runtime
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  deinit {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    clearObservers()
    guard let window else { return }
    addObservers(for: window)
    apply()
    applyAppearance()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    apply()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  private func apply() {
    guard let window else { return }
    WindowChromeApplier.apply(window: window, runtime: runtime, lastApplied: &lastApplied)
  }

  // The window appearance is updated only here, on genuine terminal-appearance
  // changes, so it never flashes on key/occlusion/alert events.
  private func applyAppearance() {
    guard let window else { return }
    WindowChromeApplier.applyWindowAppearance(window: window, runtime: runtime)
  }

  private func addObservers(for window: NSWindow) {
    let center = NotificationCenter.default
    let windowNotifications: [Notification.Name] = [
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didChangeScreenNotification,
    ]
    for name in windowNotifications {
      observers.append(
        center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          Task { @MainActor [weak self] in self?.apply() }
        }
      )
    }
    observers.append(
      center.addObserver(
        forName: .ghosttyRuntimeConfigDidChange,
        object: runtime,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.lastApplied = nil
          self?.apply()
          self?.applyAppearance()
        }
      }
    )
    // Focus move or OSC 11 on the focused surface re-tints the window and updates
    // its appearance. Posted by the manager (object: manager), so match any object.
    observers.append(
      center.addObserver(
        forName: .ghosttyFocusedSurfaceBackgroundDidChange,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.apply()
          self?.applyAppearance()
        }
      }
    )
  }

  private func clearObservers() {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
    }
    observers.removeAll()
  }
}
