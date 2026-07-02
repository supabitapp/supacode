import AppKit
import GhosttyKit
import SupacodeSettingsShared
import SwiftUI

private nonisolated let chromeLogger = SupaLogger("WindowChrome")

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
      // Near-transparent backing so the window-wide blur shows through and the
      // tint is carried by `WindowTintBackdrop`, which masks the surface regions
      // out of it. A surface then composites over blur (its own opacity),
      // never over the tint (no double background).
      window.backgroundColor = NSColor.white.withAlphaComponent(0.001)
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
    return
      "\(Int(srgb.redComponent * 255)),\(Int(srgb.greenComponent * 255)),\(Int(srgb.blueComponent * 255))"
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
    applyChrome()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    // Reclaim the terminal-driven window.appearance: a global appearance set
    // (GhosttyColorSchemeSyncView's NSApp.appearance, or a system Light/Dark
    // flip) changes the effective appearance and would otherwise leave the
    // toolbar stuck on the wrong scheme. The guard in applyWindowAppearance
    // makes the re-set a no-op once it matches.
    applyChrome()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  // Background + appearance together, for genuine terminal-appearance changes.
  // The window-event observers call apply() alone on purpose: retinting the
  // appearance on key/occlusion events would flash the window.
  private func applyChrome() {
    apply()
    applyAppearance()
  }

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
          self?.applyChrome()
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
        Task { @MainActor [weak self] in self?.applyChrome() }
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

// Mounted from ContentView. Installs a single tint layer in the window's frame
// view, behind the content view, carrying the focused-surface tint with each
// terminal surface's rect masked OUT of it. The tint shows behind the chrome
// (sidebar / toolbar / tab bar / empty detail); the surface holes reveal the
// window blur so a translucent surface composites over blur, never over the
// tint.
struct WindowTintBackdrop: NSViewRepresentable {
  let runtime: GhosttyRuntime

  func makeNSView(context: Context) -> WindowTintBackdropFinder {
    WindowTintBackdropFinder(runtime: runtime)
  }

  func updateNSView(_ nsView: WindowTintBackdropFinder, context: Context) {}
}

@MainActor
final class WindowTintBackdropFinder: NSView {
  private let runtime: GhosttyRuntime
  private weak var backdrop: TintBackdropView?

  init(runtime: GhosttyRuntime) {
    self.runtime = runtime
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // The tint layer must live in the window's frame view (NSThemeFrame),
    // BELOW the SwiftUI hosting view: that is the only in-window level the
    // translucent chrome (sidebar / toolbar vibrancy, tab bar, detail)
    // actually reveals. A subview of `contentView` is never sampled by it.
    guard let contentView = window?.contentView,
      let frameView = contentView.superview
    else {
      // Window nil is normal teardown; a window without a reachable frame view
      // means the private hierarchy changed and the tint silently vanishes.
      if window != nil {
        chromeLogger.warning("Window frame view unavailable; tint backdrop not installed")
      }
      backdrop?.removeFromSuperview()
      backdrop = nil
      return
    }
    if backdrop?.superview !== frameView {
      backdrop?.removeFromSuperview()
      let view = TintBackdropView(runtime: runtime)
      view.translatesAutoresizingMaskIntoConstraints = true
      view.autoresizingMask = [.width, .height]
      view.frame = frameView.bounds
      frameView.addSubview(view, positioned: .below, relativeTo: contentView)
      view.refresh()
      backdrop = view
    }
  }
}

@MainActor
final class TintBackdropView: NSView {
  private let runtime: GhosttyRuntime
  private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
  // Coalesces the surface-rect walk to one rebuild per runloop tick: a worktree
  // switch / split resize fires dozens of layout + frame notifications, and each
  // synchronous rebuild walked the whole window hierarchy, which stalled the switch.
  private var maskRebuildScheduled = false

  init(runtime: GhosttyRuntime) {
    self.runtime = runtime
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = false
    addObservers()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  deinit {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    // Color is cheap, keep it in lockstep with bounds; the mask walk coalesces.
    refreshColor()
    setNeedsMaskRebuild()
  }

  // The no-surface fallback tint can be a dynamic color (windowBackgroundColor),
  // and `cgColor` freezes its resolution; re-resolve when the appearance flips.
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshColor()
  }

  private func addObservers() {
    let center = NotificationCenter.default
    // A background change only recolors the fill, a frame change only moves the
    // mask holes, and a config change can alter both (opacity + theme color).
    observers.append(
      center.addObserver(
        forName: .ghosttyFocusedSurfaceBackgroundDidChange, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.refreshColor() }
      }
    )
    observers.append(
      center.addObserver(
        forName: .ghosttySurfaceFrameDidChange, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.setNeedsMaskRebuild() }
      }
    )
    observers.append(
      center.addObserver(
        forName: .ghosttyRuntimeConfigDidChange, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.refreshColor()
          self?.setNeedsMaskRebuild()
        }
      }
    )
  }

  func refresh() {
    refreshColor()
    rebuildMask()
  }

  // Tint at the shared background-opacity so the chrome fill matches the
  // surfaces exactly (one homogeneous fill over the same window blur).
  private func refreshColor() {
    guard let layer else { return }
    layer.backgroundColor =
      runtime.windowTintColor().withAlphaComponent(runtime.backgroundOpacity()).cgColor
  }

  private func setNeedsMaskRebuild() {
    guard !maskRebuildScheduled else { return }
    maskRebuildScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.maskRebuildScheduled = false
      self.rebuildMask()
    }
  }

  // Each terminal surface's rect is punched as a hole so behind a surface there
  // is only blur, and the surface paints its own OSC 11 color over it at the same
  // opacity (no double background, seamless with the chrome).
  private func rebuildMask() {
    guard layer != nil else { return }
    let path = CGMutablePath()
    path.addRect(bounds)
    if let frameView = superview {
      for surface in Self.surfaceViews(in: frameView)
      where !surface.isHiddenOrHasHiddenAncestor {
        let rect = surface.convert(surface.bounds, to: self)
        guard rect.width > 0, rect.height > 0, rect.intersects(bounds) else { continue }
        path.addRect(rect)
      }
    } else {
      // No holes get punched, so the tint would double behind every surface.
      chromeLogger.warning("Tint backdrop has no superview; mask rebuilt without surface holes")
    }
    let mask = CAShapeLayer()
    mask.frame = bounds
    mask.path = path
    mask.fillRule = .evenOdd
    layer?.mask = mask
  }

  private static func surfaceViews(in root: NSView) -> [GhosttySurfaceView] {
    var result: [GhosttySurfaceView] = []
    if let surface = root as? GhosttySurfaceView {
      result.append(surface)
    }
    for subview in root.subviews {
      result.append(contentsOf: surfaceViews(in: subview))
    }
    return result
  }
}
