import AppKit
import SwiftUI

extension View {
  // Override `\.colorScheme` to match the terminal background's luminance so
  // text/icons painted over the window tint (loading view, multi-select,
  // empty states) stay readable when the user's system appearance differs
  // from the Ghostty theme — e.g. light system + dark terminal background.
  func windowTintColorScheme(manager: WorktreeTerminalManager) -> some View {
    modifier(WindowTintColorScheme(manager: manager))
  }

  // Toolbar variant: match the terminal luminance while windowed but keep the system
  // scheme in fullscreen (system-painted titlebar). Stands in for the vibrant
  // foreground a full-color toolbar icon opts its item out of. `isFullScreen` must
  // come from `windowFullScreenObserver` on the content, not the re-hosted toolbar.
  func toolbarTintColorScheme(manager: WorktreeTerminalManager, isFullScreen: Bool) -> some View {
    modifier(ToolbarTintColorScheme(manager: manager, isFullScreen: isFullScreen))
  }

  // Reports the host window's fullscreen state. Mount on content in the main terminal
  // window (which genuinely enters fullscreen), never on toolbar content.
  func windowFullScreenObserver(isFullScreen: Binding<Bool>) -> some View {
    background(WindowFullScreenObserver(isFullScreen: isFullScreen))
  }
}

private struct WindowTintColorScheme: ViewModifier {
  let manager: WorktreeTerminalManager
  // Captured here, BEFORE the override below replaces `\.colorScheme`. Anything
  // that reads `@Environment(\.colorScheme)` underneath the override would
  // otherwise see the overridden value and `inheritSystemColorScheme()` would
  // be a no-op.
  @Environment(\.colorScheme) private var systemColorScheme
  @State private var configReloadCounter = 0

  func body(content: Content) -> some View {
    // Force-track these dependencies so SwiftUI re-evaluates body and re-resolves
    // `surfaceBackgroundColorScheme()` (an opaque AppKit read) on system Light/Dark
    // flips and on Ghostty config reloads.
    _ = configReloadCounter
    _ = systemColorScheme
    let tintScheme = manager.surfaceBackgroundColorScheme()
    let appearance = SurfaceChromeAppearance(
      colorScheme: tintScheme,
      systemColorScheme: systemColorScheme
    )
    return
      content
      .environment(\.surfaceChromeAppearance, appearance)
      .environment(\.colorScheme, tintScheme)
      .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigDidChange)) { _ in
        configReloadCounter &+= 1
      }
  }
}

private struct ToolbarTintColorScheme: ViewModifier {
  let manager: WorktreeTerminalManager
  let isFullScreen: Bool
  @Environment(\.colorScheme) private var systemColorScheme
  @State private var configReloadCounter = 0

  func body(content: Content) -> some View {
    _ = configReloadCounter
    _ = systemColorScheme
    // Fullscreen: system-painted titlebar, so keep the system scheme. Windowed: the
    // toolbar overlays the terminal, so match the terminal background.
    let tintScheme = isFullScreen ? systemColorScheme : manager.surfaceBackgroundColorScheme()
    let appearance = SurfaceChromeAppearance(
      colorScheme: tintScheme,
      systemColorScheme: systemColorScheme
    )
    return
      content
      .environment(\.surfaceChromeAppearance, appearance)
      .environment(\.colorScheme, tintScheme)
      .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigDidChange)) { _ in
        configReloadCounter &+= 1
      }
  }
}

private struct WindowFullScreenObserver: NSViewRepresentable {
  @Binding var isFullScreen: Bool

  func makeNSView(context: Context) -> WindowFullScreenObserverNSView {
    let view = WindowFullScreenObserverNSView()
    view.onChange = { isFullScreen = $0 }
    return view
  }

  func updateNSView(_ nsView: WindowFullScreenObserverNSView, context: Context) {}
}

@MainActor
final class WindowFullScreenObserverNSView: NSView {
  var onChange: ((Bool) -> Void)?
  // `nonisolated(unsafe)` so the nonisolated `deinit` can release the tokens;
  // NotificationCenter is thread-safe and only main-actor methods mutate the array.
  private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

  deinit {
    let center = NotificationCenter.default
    for observer in observers { center.removeObserver(observer) }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    let center = NotificationCenter.default
    for observer in observers { center.removeObserver(observer) }
    observers.removeAll()
    guard let window else { return }
    onChange?(window.styleMask.contains(.fullScreen))
    for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
      observers.append(
        center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            self.onChange?(window.styleMask.contains(.fullScreen))
          }
        }
      )
    }
  }
}
