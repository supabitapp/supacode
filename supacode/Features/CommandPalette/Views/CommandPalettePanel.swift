import AppKit
import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

extension NSEvent {
  /// `isARepeat` raises on anything but a key event, and a menu action reads the current
  /// event, which is a mouse event when the item is clicked. Gate on the type first.
  var isAutoRepeatKeyDown: Bool {
    type == .keyDown && isARepeat
  }
}

/// Floating key panel that hosts the command palette. Living in its own window
/// keeps the main window's first responder untouched, so dismissing the palette
/// returns keyboard focus to the terminal via the normal key-window sync (no
/// manual focus restore needed). Kept `.titled` (with the titlebar chrome hidden)
/// so the system applies the standard window corner radius, shadow, and border.
final class CommandPalettePanel: NSPanel {
  // Fixed size (field + result list), matching the previous palette. The window
  // is not resized dynamically: a `.titled` window lays out via constraints, and
  // resizing it during a layout pass recurses and aborts.
  static let contentSize = NSSize(width: 500, height: 254)

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  init() {
    super.init(
      contentRect: NSRect(origin: .zero, size: Self.contentSize),
      styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
      backing: .buffered,
      defer: true
    )
    isFloatingPanel = true
    level = .floating
    isMovableByWindowBackground = false
    backgroundColor = .clear
    isOpaque = false
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true
    // Keep the palette visible when the main window is in native fullscreen.
    collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    animationBehavior = .none
  }

  // Esc while the query field is empty routes here; forward it as a dismiss.
  override func cancelOperation(_ sender: Any?) {
    onCancel?()
  }

  var onCancel: (() -> Void)?
}

/// Background observer (mounted in `ContentView`) that owns the palette panel
/// and shows / hides it in step with `isPresented`. Mirrors `WindowChromeObserver`.
struct CommandPalettePanelHost: NSViewRepresentable {
  let store: StoreOf<CommandPaletteFeature>
  let items: [CommandPaletteItem]
  let isPresented: Bool

  func makeNSView(context: Context) -> CommandPalettePanelHostView {
    CommandPalettePanelHostView(store: store)
  }

  func updateNSView(_ nsView: CommandPalettePanelHostView, context: Context) {
    nsView.update(store: store, items: items, isPresented: isPresented)
  }

  static func dismantleNSView(_ nsView: CommandPalettePanelHostView, coordinator: ()) {
    nsView.tearDown()
  }
}

@MainActor
final class CommandPalettePanelHostView: NSView {
  private var store: StoreOf<CommandPaletteFeature>
  private var items: [CommandPaletteItem] = []
  private var panel: CommandPalettePanel?
  private var hostingView: NSHostingView<CommandPaletteOverlayView>?
  private nonisolated(unsafe) var resignObserver: NSObjectProtocol?
  private nonisolated(unsafe) var keyMonitor: Any?
  /// Held, not constructed per keystroke: the shared reference is cached weakly,
  /// so a local would re-read the settings file on every key event.
  @Shared(.settingsFile) private var settingsFile

  init(store: StoreOf<CommandPaletteFeature>) {
    self.store = store
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  deinit {
    if let resignObserver {
      NotificationCenter.default.removeObserver(resignObserver)
    }
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func update(store: StoreOf<CommandPaletteFeature>, items: [CommandPaletteItem], isPresented: Bool) {
    self.store = store
    self.items = items
    guard isPresented else {
      hidePanel()
      return
    }
    // Already shown: refresh content only, preserving the in-flight query,
    // selection, and query-field focus against a background items refresh.
    if let hostingView {
      hostingView.rootView = CommandPaletteOverlayView(store: store, items: items)
      return
    }
    showPanel(items: items)
  }

  func tearDown() {
    hidePanel()
    panel = nil
  }

  private func showPanel(items: [CommandPaletteItem]) {
    guard let mainWindow = window else { return }
    let panel = self.panel ?? makePanel()
    // Fresh hosting view on every present so `CommandPaletteOverlayView.task`
    // re-runs and re-asserts first responder on the query field. The panel and
    // its observer are reused, but `orderOut` alone never re-fires the task.
    let hostingView = NSHostingView(
      rootView: CommandPaletteOverlayView(store: store, items: items)
    )
    // Fill to the top edge: the titled window's hidden titlebar would otherwise
    // inset the content via the safe area, leaving a gap above the search field.
    hostingView.safeAreaRegions = []

    // Tahoe liquid glass is the panel's only background. The panel, the hosting
    // view, and the SwiftUI card are all transparent; the titled window applies
    // the corner radius and clips to it, so the glass needs no radius of its own.
    let glass = NSGlassEffectView()
    glass.contentView = hostingView

    panel.contentView = glass
    self.hostingView = hostingView
    position(panel: panel, over: mainWindow)
    if panel.parent == nil {
      mainWindow.addChildWindow(panel, ordered: .above)
    }
    installKeyMonitorIfNeeded()
    panel.makeKeyAndOrderFront(nil)
  }

  // While the palette is key it must be the sole keystroke receiver: route each
  // key-down through the panel's own shortcut handling first (its ⌘1..⌘5, arrow,
  // and ctrl navigation), then swallow anything it and the field don't consume
  // so no app-menu shortcut or window behind ever sees it.
  private func installKeyMonitorIfNeeded() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
      if panel.performKeyEquivalent(with: event) { return nil }
      // Drive the palette's navigation / activation shortcuts (⌘1..⌘5, arrow
      // keys, ⌃P / ⌃N) here: in-view `.keyboardShortcut` buttons don't fire
      // through the panel's `performKeyEquivalent` and would stay registered
      // app-wide for the hosting view's lifetime.
      if let index = Self.paletteActivationIndex(for: event) {
        self.activatePaletteItem(at: index)
        return nil
      }
      // The palette's own shortcuts toggle it: same mode closes, the other mode
      // switches surface. Matched here because the monitor runs ahead of the main
      // menu, so the ⌘P / ⌘⇧P menu items never see the key while the panel is key.
      // Ahead of the move matcher so a shortcut rebound onto ⌃P / ⌃N still toggles,
      // but behind ⌘1..⌘5, which the rows render and must keep honoring.
      if let mode = Self.paletteToggleMode(for: event, overrides: self.settingsFile.global.shortcutOverrides) {
        // Swallow auto-repeat rather than toggling on it: a held chord would flip the
        // palette open and closed. The menu items guard the same way, because closing
        // tears this monitor down and the next repeat would reach them instead.
        if !event.isAutoRepeatKeyDown {
          self.store.send(.togglePresentInMode(mode))
        }
        return nil
      }
      if let moveUp = Self.paletteMoveIsUp(for: event) {
        self.movePaletteSelection(up: moveUp)
        return nil
      }
      // Command chords the palette can't resolve must not leak to the app behind
      // it: route standard field editing (⌘C/⌘V/⌘X/⌘A) to the responder chain,
      // and beep on anything else.
      if event.modifierFlags.contains(.command) {
        if !Self.dispatchFieldEditingAction(for: event) {
          NSSound.beep()
        }
        return nil
      }
      // Control / option chords must not leak to app-menu key equivalents behind
      // the palette (e.g. ⌃1..⌃9 worktree selection). Hand them to the search
      // field so ⌃A/⌃E/⌥⌫ editing still works, then swallow them.
      let modifiers = Self.coreModifiers(of: event)
      if modifiers.contains(.control) || modifiers.contains(.option) {
        panel.firstResponder?.keyDown(with: event)
        return nil
      }
      return event
    }
  }

  private static func dispatchFieldEditingAction(for event: NSEvent) -> Bool {
    guard let selector = Self.fieldEditingSelector(for: event) else { return false }
    return NSApp.sendAction(selector, to: nil, from: nil)
  }

  // Modifiers that matter for shortcut matching, dropping the incidental
  // `.capsLock` / `.function` / `.numericPad` flags that keys carry so an active
  // Caps Lock (or an arrow's function flag) can't defeat an exact match.
  private static func coreModifiers(of event: NSEvent) -> NSEvent.ModifierFlags {
    event.modifierFlags.intersection([.command, .control, .option, .shift])
  }

  // Standard search-field editing chords, dispatched down the responder chain to
  // the field editor. `nil` for anything else so it beeps instead of leaking.
  private static func fieldEditingSelector(for event: NSEvent) -> Selector? {
    guard Self.coreModifiers(of: event) == .command else { return nil }
    if event.keyCode == 51 {  // Delete / backspace.
      return #selector(NSStandardKeyBindingResponding.deleteToBeginningOfLine(_:))
    }
    switch event.specialKey {
    case .leftArrow: return #selector(NSStandardKeyBindingResponding.moveToBeginningOfLine(_:))
    case .rightArrow: return #selector(NSStandardKeyBindingResponding.moveToEndOfLine(_:))
    default: break
    }
    // Lowercase: Caps Lock uppercases `charactersIgnoringModifiers`.
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "x": return #selector(NSText.cut(_:))
    case "c": return #selector(NSText.copy(_:))
    case "v": return #selector(NSText.paste(_:))
    case "a": return #selector(NSText.selectAll(_:))
    default: return nil
    }
  }

  // The mode whose shortcut this event matches, honoring user rebinds. `nil` when the
  // user disabled the shortcut, so a disabled chord keeps falling through to the beep.
  private static func paletteToggleMode(
    for event: NSEvent,
    overrides: [AppShortcutID: AppShortcutOverride]
  ) -> CommandPaletteFeature.PaletteMode? {
    if AppShortcuts.worktreeSwitcher.effective(from: overrides)?.matches(event) == true {
      return .worktreeSwitcher
    }
    if AppShortcuts.commandPalette.effective(from: overrides)?.matches(event) == true {
      return .commands
    }
    return nil
  }

  private static func paletteActivationIndex(for event: NSEvent) -> Int? {
    guard Self.coreModifiers(of: event) == .command else { return nil }
    guard let characters = event.charactersIgnoringModifiers, let digit = Int(characters),
      (1...5).contains(digit)
    else {
      return nil
    }
    return digit
  }

  // `true` for up (↑ / ⌃P), `false` for down (↓ / ⌃N), `nil` otherwise.
  private static func paletteMoveIsUp(for event: NSEvent) -> Bool? {
    switch event.specialKey {
    case .upArrow: return true
    case .downArrow: return false
    default: break
    }
    guard Self.coreModifiers(of: event) == .control,
      // Lowercase: Caps Lock uppercases `charactersIgnoringModifiers`.
      let characters = event.charactersIgnoringModifiers?.lowercased()
    else {
      return nil
    }
    switch characters {
    case "p": return true
    case "n": return false
    default: return nil
    }
  }

  private func filteredPaletteItems() -> [CommandPaletteItem] {
    CommandPaletteFeature.filterItems(
      items: items,
      query: store.query,
      mode: store.mode,
      recencyByID: store.recencyByItemID,
      now: .now
    )
  }

  private func activatePaletteItem(at index: Int) {
    let filtered = filteredPaletteItems()
    guard filtered.indices.contains(index - 1) else {
      NSSound.beep()
      return
    }
    store.send(.activateItem(filtered[index - 1]))
  }

  private func movePaletteSelection(up: Bool) {
    store.send(.moveSelection(up ? .upSelection : .downSelection, itemsCount: filteredPaletteItems().count))
  }

  private func removeKeyMonitor() {
    guard let keyMonitor else { return }
    NSEvent.removeMonitor(keyMonitor)
    self.keyMonitor = nil
  }

  private func hidePanel() {
    // Drop the hosting view so the next present builds a fresh one (re-running
    // the focus task); the panel and its observer are kept for reuse.
    removeKeyMonitor()
    hostingView = nil
    guard let panel else { return }
    if panel.isVisible {
      let parent = panel.parent
      parent?.removeChildWindow(panel)
      panel.orderOut(nil)
      // Reclaim key on the main window so its preserved first responder (and the
      // terminal-focus sync driven by `didBecomeKey`) is restored, but only when
      // the dismissal stayed inside the app and nothing else took key: if the user
      // dismissed by clicking another in-app window (e.g. Settings), re-keying here
      // would steal focus from it; if they left the app entirely (Cmd-Tab, another
      // app), `keyWindow` is also nil, so the `isActive` guard avoids yanking focus
      // back from the app they switched to.
      if NSApp.isActive, NSApp.keyWindow == nil, let parent {
        parent.makeKey()
      }
    }
    // Release the content tree, not just our reference: a retained NSHostingView
    // keeps any SwiftUI keyboard shortcuts registered app-wide even while the
    // panel is ordered out, stealing those keys from the rest of the app.
    panel.contentView = nil
  }

  private func makePanel() -> CommandPalettePanel {
    let panel = CommandPalettePanel()
    panel.onCancel = { [weak self] in self?.dismiss() }
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: panel,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.dismiss() }
    }
    self.panel = panel
    return panel
  }

  // Click-away / Esc close the palette through the store so the reducer clears
  // its transient state; guarded so ordering the panel out doesn't re-fire.
  private func dismiss() {
    guard store.isPresented else { return }
    store.send(.setPresented(false))
  }

  private func position(panel: CommandPalettePanel, over mainWindow: NSWindow) {
    let content = mainWindow.contentLayoutRect
    let origin = mainWindow.convertPoint(toScreen: content.origin)
    let size = CommandPalettePanel.contentSize
    let minX = origin.x + (content.width - size.width) / 2
    // Card top sits ~30% down the content area, matching the previous overlay.
    let topLeftY = origin.y + content.height - max(0, content.height * 0.3)
    let minY = max(origin.y, topLeftY - size.height)
    panel.setFrame(NSRect(x: minX, y: minY, width: size.width, height: size.height), display: false)
  }
}
