import AppKit
import Carbon
import CoreText
import GhosttyKit
import QuartzCore
import Sharing
import SupacodeSettingsShared
import UniformTypeIdentifiers

private let surfaceLogger = SupaLogger("Surface")

// Terminal content follows the pointer under layout-level focus-follows-mouse.
extension GhosttySurfaceView: HoverFocusEligibleResponder {}

final class GhosttySurfaceView: NSView, Identifiable {
  private struct ScrollbarState {
    let total: UInt64
    let offset: UInt64
    let length: UInt64
  }

  struct KeyboardLayoutChangeKeyUpSuppression: Equatable {
    static let lifetime: TimeInterval = 1

    let keyCode: UInt16
    let expiresAt: TimeInterval

    init(keyCode: UInt16, timestamp: TimeInterval) {
      self.keyCode = keyCode
      expiresAt = timestamp + Self.lifetime
    }

    func suppresses(keyCode: UInt16, timestamp: TimeInterval) -> Bool {
      timestamp <= expiresAt && self.keyCode == keyCode
    }

    func isExpired(at timestamp: TimeInterval) -> Bool {
      timestamp > expiresAt
    }
  }

  // Expiry is checked on read, so no timer or task outlives a fetch.
  final class CachedValue<T, C: Clock<Duration>> {
    private var entry: (value: T, fetchedAt: C.Instant)?
    private let clock: C
    private let duration: Duration

    init(clock: C, duration: Duration) {
      self.clock = clock
      self.duration = duration
    }

    nonisolated deinit {}

    // A nil fetch is a failed read: return nil and drop any stale entry rather than cache it.
    func value(orFetch fetch: () -> T?) -> T? {
      let now = clock.now
      if let entry, entry.fetchedAt.duration(to: now) < duration {
        return entry.value
      }
      guard let value = fetch() else {
        entry = nil
        return nil
      }
      entry = (value, now)
      return value
    }

    func invalidate() {
      entry = nil
    }
  }

  private let runtime: GhosttyRuntime
  let id: UUID
  let bridge: GhosttySurfaceBridge
  private(set) var surface: ghostty_surface_t?
  private var surfaceRef: GhosttyRuntime.SurfaceReference?
  private let workingDirectoryCString: UnsafeMutablePointer<CChar>?
  private let commandCString: UnsafeMutablePointer<CChar>?
  private let initialInputCString: UnsafeMutablePointer<CChar>?
  private let environmentVariables: [String: String]
  /// Argv prepended to Ghostty's resolved command (e.g. `zmx attach <id>`), so
  /// the real shell runs as a child of the wrapper. Empty means no wrapper.
  private let commandWrapper: [String]
  /// Forces `shell-integration = none` for this surface only. Used by
  /// self-managing surfaces (blocking-script runners) that emit their own OSC
  /// sequences and must not have Ghostty's integration injected.
  private let disableShellIntegration: Bool
  private let fontSize: Float32
  // Display scale carried from creation-time geometry, authoritative until the
  // view joins a window.
  private let initialScale: CGFloat
  // The scale last pushed to the terminal core; the frozen grid must record
  // this one, since the applied backing size was measured under it.
  private var appliedContentScale: CGFloat
  private let context: ghostty_surface_context_e
  private var trackingArea: NSTrackingArea?
  // Only ever holds sizes actually pushed to ghostty_surface_set_size; a rejected
  // degenerate size must be re-evaluated on the next layout pass.
  private var lastAppliedBackingSize: CGSize = .zero
  private var lastPerformKeyEvent: TimeInterval?
  private var currentCursor: NSCursor = .iBeam
  private var focused = false
  // Held so the per-chord check doesn't build a fresh reference.
  @Shared(.settingsFile) private var settingsFile
  // Event number of the left press this view forwarded; only the release sharing it is sent.
  private(set) var forwardedLeftPressNumber: Int?
  private var markedText = NSMutableAttributedString()
  private var keyboardLayoutChangeKeyUpSuppression: KeyboardLayoutChangeKeyUpSuppression?
  // Agent presence pushed from app state; gates Cmd+V image-paste routing.
  var imagePasteAgents: Set<SkillAgent> = []
  private var keyTextAccumulator: [String]?
  private var cellSize: CGSize = .zero
  private var lastScrollbar: ScrollbarState?
  private(set) var lastOcclusion: Bool?
  private var lastSurfaceFocus: Bool?
  private var notificationObservers: [NSObjectProtocol] = []
  private var prevPressureStage: Int = 0
  private let cachedScreenContents = CachedValue<String, ContinuousClock>(
    clock: ContinuousClock(),
    duration: .milliseconds(500)
  )
  var passwordInput: Bool = false {
    didSet {
      let input = SecureInput.shared
      let id = ObjectIdentifier(self)
      if passwordInput {
        input.setScoped(id, focused: focused)
      } else {
        input.removeScoped(id)
      }
    }
  }
  weak var scrollWrapper: GhosttySurfaceScrollView? {
    didSet {
      if let lastScrollbar {
        scrollWrapper?.updateScrollbar(
          total: lastScrollbar.total,
          offset: lastScrollbar.offset,
          length: lastScrollbar.length
        )
      }
    }
  }
  // Strong hold forms a surface<->wrapper cycle, so `closeSurface` must release
  // it; `deinit` cannot free the surface until it has.
  private var ownedScrollWrapper: GhosttySurfaceScrollView?

  /// The view a content host mounts for this surface: its scroll wrapper, built
  /// once and reused across remounts so a rebuild or worktree switch reparents
  /// it and the live surface keeps its painted frames, instead of rebuilding at
  /// zero size.
  func hostedView() -> GhosttySurfaceScrollView {
    if let ownedScrollWrapper { return ownedScrollWrapper }
    let wrapper = GhosttySurfaceScrollView(surfaceView: self)
    ownedScrollWrapper = wrapper
    return wrapper
  }
  var onFocusChange: ((Bool) -> Void)?
  /// Asks the owning state to re-derive activity because user input reached an
  /// occluded surface, passing the window's fresh key/visibility readings so
  /// input alone never stamps unproven visibility into the state.
  var onOcclusionHeal: ((_ windowIsKey: Bool, _ windowIsVisible: Bool) -> Void)?
  /// Asked on re-attachment to a window: should this surface re-claim
  /// firstResponder right now? SwiftUI detaches sibling panes during split
  /// rebuilds (e.g. after closing a surface), and AppKit doesn't auto-promote
  /// a re-attached view, so without this hook the recorded focus owner sits in
  /// the tree without listening to keystrokes. Only consulted on RE-attachment
  /// (not the first mount) so we never fight the initial-focus path.
  var shouldClaimFocus: (() -> Bool)?
  /// Set the first time this view lands in a real window. The self-claim path
  /// is gated on this so it only fires for the re-attachment case.
  private var hasBeenInWindow = false
  /// Outstanding self-claim Task from the most recent re-attach. Rapid split
  /// rebuilds would otherwise queue one Task per attach; cancelling the prior
  /// keeps the queue at most one deep without changing correctness (each Task
  /// is already idempotent on its own guards).
  private var pendingFocusClaim: Task<Void, Never>?

  private var accessibilityPaneIndexHelp: String?

  private static let mouseCursorMap: [ghostty_action_mouse_shape_e: NSCursor] = [
    GHOSTTY_MOUSE_SHAPE_DEFAULT: .arrow,
    GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam,
    GHOSTTY_MOUSE_SHAPE_GRAB: .openHand,
    GHOSTTY_MOUSE_SHAPE_GRABBING: .closedHand,
    GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand,
    GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: .iBeamCursorForVerticalLayout,
    GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: .contextualMenu,
    GHOSTTY_MOUSE_SHAPE_CROSSHAIR: .crosshair,
    GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: .operationNotAllowed,
  ]

  private static let mouseResizeLeftRightShapes: Set<ghostty_action_mouse_shape_e> = [
    GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
    GHOSTTY_MOUSE_SHAPE_W_RESIZE,
    GHOSTTY_MOUSE_SHAPE_E_RESIZE,
    GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
  ]

  private static let mouseResizeUpDownShapes: Set<ghostty_action_mouse_shape_e> = [
    GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
    GHOSTTY_MOUSE_SHAPE_N_RESIZE,
    GHOSTTY_MOUSE_SHAPE_S_RESIZE,
    GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
  ]
  private static let dropTypes: Set<NSPasteboard.PasteboardType> = [
    .string,
    .fileURL,
    .URL,
  ]

  static func normalizedWorkingDirectoryPath(_ path: String) -> String {
    var normalized = path
    while normalized.count > 1 && normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized
  }

  static func accessibilityLine(for index: Int, in content: String) -> Int {
    // Accessibility indices are UTF-16 offsets.
    let clampedIndex = min(max(index, 0), content.utf16.count)
    let prefix = String(decoding: content.utf16.prefix(clampedIndex), as: UTF16.self)
    return max(0, prefix.components(separatedBy: .newlines).count - 1)
  }

  static func accessibilityString(for range: NSRange, in content: String) -> String? {
    let utf16 = content.utf16
    guard range.location >= 0, range.length >= 0, range.location <= utf16.count,
      range.length <= utf16.count - range.location
    else { return nil }
    let start = utf16.index(utf16.startIndex, offsetBy: range.location)
    let end = utf16.index(start, offsetBy: range.length)
    // Decode lossily so a range splitting a surrogate pair yields U+FFFD instead of nil.
    return String(decoding: utf16[start..<end], as: UTF16.self)
  }

  override var acceptsFirstResponder: Bool { true }

  init(
    id: UUID,
    runtime: GhosttyRuntime,
    workingDirectory: URL?,
    command: String? = nil,
    initialInput: String? = nil,
    environmentVariables: [String: String] = [:],
    commandWrapper: [String] = [],
    disableShellIntegration: Bool = false,
    fontSize: Float32? = nil,
    initialGeometry: ContentGeometry,
    context: ghostty_surface_context_e
  ) {
    self.id = id
    self.runtime = runtime
    self.bridge = GhosttySurfaceBridge()
    self.fontSize = fontSize ?? 0
    self.initialScale = initialGeometry.scale
    self.appliedContentScale = initialGeometry.scale
    self.context = context
    self.environmentVariables = environmentVariables
    self.commandWrapper = commandWrapper
    self.disableShellIntegration = disableShellIntegration
    if let workingDirectory {
      let path = Self.normalizedWorkingDirectoryPath(
        workingDirectory.path(percentEncoded: false)
      )
      workingDirectoryCString = path.withCString { strdup($0) }
    } else {
      workingDirectoryCString = nil
    }
    if let command {
      commandCString = command.withCString { strdup($0) }
    } else {
      commandCString = nil
    }
    if let initialInput {
      initialInputCString = initialInput.withCString { strdup($0) }
    } else {
      initialInputCString = nil
    }
    // Off-window backing conversion is 1x, so a point frame equal to the intended
    // pixel size makes ghostty_surface_new spawn the PTY at an honest grid (#780).
    super.init(frame: NSRect(origin: .zero, size: initialGeometry.pixelSize))
    wantsLayer = true
    bridge.surfaceView = self
    createSurface()
    if let surface {
      surfaceRef = runtime.registerSurface(surface)
    }
    registerForDraggedTypes(Array(Self.dropTypes))

    LocalEventMonitor.installIfNeeded()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  nonisolated deinit {
    MainActor.assumeIsolated {
      clearNotificationObservers()
      SecureInput.shared.removeScoped(ObjectIdentifier(self))
      // A live surface here means a teardown path bypassed `closeSurface`; the
      // call below still frees it, off the turn.
      if surface != nil {
        assertionFailure("GhosttySurfaceView deallocated with a live surface; a teardown path bypassed closeSurface().")
      }
      closeSurface()
      if let workingDirectoryCString {
        free(workingDirectoryCString)
      }
      if let commandCString {
        free(commandCString)
      }
      if let initialInputCString {
        free(initialInputCString)
      }
    }
  }

  var needsCloseConfirmation: Bool {
    guard let surface else { return false }
    return ghostty_surface_needs_confirm_quit(surface)
  }

  func closeSurface() {
    clearNotificationObservers()
    cachedScreenContents.invalidate()
    LocalEventMonitor.surfaceClosed(self)
    forwardedLeftPressNumber = nil
    // Break the surface<->wrapper cycle; the strong hold otherwise blocks deinit.
    defer { ownedScrollWrapper = nil }
    guard let surface else { return }
    if let surfaceRef {
      runtime.unregisterSurface(surfaceRef)
      self.surfaceRef = nil
    }
    self.surface = nil
    bridge.surface = nil
    lastOcclusion = nil
    lastSurfaceFocus = nil
    // Hide before the free so the "[Process exited]" overlay can't paint while
    // the layout collapses around the closing pane.
    isHidden = true
    // Free off the current turn on the main queue: `ghostty_surface_free` joins
    // the surface's search, renderer, and IO threads and tears down the Metal
    // renderer, which would otherwise block the reducer turn. Retain the
    // runtime and bridge by hand across the free (a Sendable block can't
    // capture them) so the Ghostty app stays alive and a synchronous callback
    // during the free still resolves a live bridge; `self` is intentionally
    // not captured, as the free never touches the surface's nsview.
    let retainedRuntime = Unmanaged.passRetained(runtime)
    let retainedBridge = Unmanaged.passRetained(bridge)
    DispatchQueue.main.async {
      ghostty_surface_free(surface)
      retainedBridge.release()
      retainedRuntime.release()
    }
  }

  private func updateScreenObservers() {
    clearNotificationObservers()
    guard let window else { return }
    let center = NotificationCenter.default
    notificationObservers.append(
      center.addObserver(
        forName: NSWindow.didChangeScreenNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.windowDidChangeScreen()
        }
      })
    notificationObservers.append(
      center.addObserver(
        forName: NSWindow.didEnterFullScreenNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.applyWindowBackgroundAppearance()
        }
      })
    notificationObservers.append(
      center.addObserver(
        forName: NSWindow.didExitFullScreenNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.applyWindowBackgroundAppearance()
        }
      })
    notificationObservers.append(
      center.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.applyWindowBackgroundAppearance()
        }
      })
    notificationObservers.append(
      center.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.applyWindowBackgroundAppearance()
        }
      })
    notificationObservers.append(
      center.addObserver(
        forName: .ghosttyRuntimeConfigDidChange,
        object: runtime,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          // Bust the equality cache so blur-only or other config changes
          // not represented in `WindowAppearanceState` still re-invoke the
          // window appearance + Ghostty blur API.
          self?.lastAppliedWindowAppearance = nil
          self?.applyWindowBackgroundAppearance()
        }
      })
  }

  private func windowDidChangeScreen() {
    guard let surface, let screen = window?.screen else { return }
    let displayID =
      screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
    ghostty_surface_set_display_id(surface, displayID)
    DispatchQueue.main.async { [weak self] in
      self?.viewDidChangeBackingProperties()
    }
  }

  private func clearNotificationObservers() {
    let center = NotificationCenter.default
    for observer in notificationObservers {
      center.removeObserver(observer)
    }
    notificationObservers.removeAll()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      // SwiftUI can temporarily detach a pane while rebuilding split/zoom layout.
      // If we keep the stale local focus bit, detached panes still intercept bindings.
      pendingFocusClaim?.cancel()
      pendingFocusClaim = nil
      focusDidChange(false)
      // A detached view gets no mouseExited, and may reattach away from the pointer.
      LocalEventMonitor.pointerExited(self)
    } else if hasBeenInWindow, shouldClaimFocus?() == true {
      // Re-attached after a split-tree rebuild dropped us. AppKit doesn't
      // auto-promote a re-attached view to firstResponder, so claim it back
      // ourselves on the next runloop tick (immediate claim is unreliable
      // when SwiftUI is mid-mount and `window` may still flip).
      let attachedWindow = window
      pendingFocusClaim?.cancel()
      pendingFocusClaim = Task { @MainActor [weak self] in
        guard
          let self,
          !Task.isCancelled,
          let window = self.window,
          window === attachedWindow,
          self.shouldClaimFocus?() == true
        else { return }
        // Only reclaim from the no-owner or sibling-terminal case. Stealing
        // from a non-terminal responder (command palette, inline rename text
        // field) mid-rebuild would yank focus from whatever the user is
        // actively typing into. The window itself is the no-owner case: AppKit
        // parks firstResponder there when the previous owner leaves the
        // hierarchy, e.g. after a split collapse.
        let responder = window.firstResponder
        guard responder !== self else { return }
        if responder == nil || responder === window || responder is GhosttySurfaceView {
          _ = window.makeFirstResponder(self)
        }
      }
    }
    if window != nil {
      hasBeenInWindow = true
    }
    updateScreenObservers()
    updateContentScale()
    notifySizeChanged()
    applyWindowBackgroundAppearance()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    // Re-resolve `NSColor.windowBackgroundColor` (and any dynamic fallback) under
    // the new appearance. `withAlphaComponent` flattens dynamic colors, so the
    // transparent branch otherwise freezes at whatever scheme was current at first paint.
    applyWindowBackgroundAppearance()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    if let window {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer?.contentsScale = window.backingScaleFactor
      CATransaction.commit()
    }
    updateContentScale()
    notifySizeChanged()
  }

  override func layout() {
    super.layout()
    notifySizeChanged()
  }

  private func notifySizeChanged() {
    if let scrollWrapper {
      scrollWrapper.updateSurfaceSize()
    } else {
      updateSurfaceSize()
    }
  }

  override func updateTrackingAreas() {
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: currentCursor)
  }

  private var lastAppliedWindowAppearance: WindowAppearanceState?

  private func applyWindowBackgroundAppearance() {
    guard let window else { return }
    WindowChromeApplier.apply(
      window: window,
      runtime: runtime,
      lastApplied: &lastAppliedWindowAppearance
    )
  }

  func toggleBackgroundOpacity() -> Bool {
    // Skip toggling when it would have no visible effect: config is fully
    // opaque, no window is available, or window is in fullscreen mode.
    guard runtime.backgroundOpacity() < 1 else {
      surfaceLogger.debug("toggleBackgroundOpacity: no-op, background is already fully opaque.")
      return false
    }
    guard let window else {
      surfaceLogger.debug("toggleBackgroundOpacity: window unavailable, skipping.")
      return false
    }
    guard !window.styleMask.contains(.fullScreen) else {
      surfaceLogger.debug("toggleBackgroundOpacity: no-op in fullscreen mode.")
      return false
    }
    runtime.toggleIsBackgroundOpaque()
    applyWindowBackgroundAppearance()
    return true
  }

  func focusDidChange(_ focused: Bool) {
    guard surface != nil else { return }
    guard self.focused != focused else { return }
    self.focused = focused
    if focused, bridge.state.bellCount != 0 {
      bridge.state.bellCount = 0
    }
    setSurfaceFocus(focused)
    onFocusChange?(focused)
    if passwordInput {
      SecureInput.shared.setScoped(ObjectIdentifier(self), focused: focused)
    }
  }

  func setAccessibilityPaneIndex(index: Int, total: Int) {
    guard total > 0, index > 0, index <= total else {
      accessibilityPaneIndexHelp = nil
      return
    }
    accessibilityPaneIndexHelp = "Pane \(index) of \(total)"
  }

  override func isAccessibilityElement() -> Bool {
    // Avoid interacting with panes after teardown.
    surface != nil
  }

  override func accessibilityRole() -> NSAccessibility.Role? {
    // Match Ghostty.app so speech/input tools can treat the surface as editable text.
    .textArea
  }

  override func accessibilityLabel() -> String? {
    let title = bridge.state.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !title.isEmpty {
      return title
    }
    let pwd = bridge.state.pwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !pwd.isEmpty {
      return pwd
    }
    return "Terminal pane"
  }

  override func accessibilityValue() -> Any? {
    screenContents
  }

  override func accessibilityHelp() -> String? {
    accessibilityPaneIndexHelp
  }

  override func accessibilitySelectedTextRange() -> NSRange {
    selectedRange()
  }

  override func accessibilitySelectedText() -> String? {
    guard let surface else { return nil }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    let value = String(cString: text.text)
    return value.isEmpty ? nil : value
  }

  override func accessibilityNumberOfCharacters() -> Int {
    screenContents.utf16.count
  }

  override func accessibilityVisibleCharacterRange() -> NSRange {
    NSRange(location: 0, length: screenContents.utf16.count)
  }

  override func accessibilityLine(for index: Int) -> Int {
    Self.accessibilityLine(for: index, in: screenContents)
  }

  override func accessibilityString(for range: NSRange) -> String? {
    Self.accessibilityString(for: range, in: screenContents)
  }

  override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
    guard let surface else { return nil }
    guard let plainString = accessibilityString(for: range) else { return nil }

    var attributes: [NSAttributedString.Key: Any] = [:]
    if let fontRaw = ghostty_surface_quicklook_font(surface) {
      let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
      attributes[.font] = font.takeUnretainedValue()
      font.release()
    }

    return NSAttributedString(string: plainString, attributes: attributes)
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result {
      focusDidChange(true)
      postAccessibilityFocusChanged()
    }
    return result
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result {
      focusDidChange(false)
    }
    return result
  }

  private func postAccessibilityFocusChanged() {
    guard surface != nil else { return }
    // Post on the window so assistive tech can query the focused element from it.
    if let window {
      NSAccessibility.post(element: window, notification: .focusedUIElementChanged)
    } else {
      NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
    }
  }

  private var screenContents: String {
    cachedScreenContents.value(orFetch: readScreenContents) ?? ""
  }

  private func readScreenContents() -> String? {
    guard let surface else { return nil }
    var text = ghostty_text_s()
    let selection = ghostty_selection_s(
      top_left: ghostty_point_s(
        tag: GHOSTTY_POINT_SCREEN,
        coord: GHOSTTY_POINT_COORD_TOP_LEFT,
        x: 0,
        y: 0
      ),
      bottom_right: ghostty_point_s(
        tag: GHOSTTY_POINT_SCREEN,
        coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
        x: 0,
        y: 0
      ),
      rectangle: false
    )
    guard ghostty_surface_read_text(surface, selection, &text) else {
      surfaceLogger.debug("Failed to read screen contents for accessibility.")
      return nil
    }
    defer { ghostty_surface_free_text(surface, &text) }
    return String(cString: text.text)
  }

  override func keyDown(with event: NSEvent) {
    healOcclusionFromUserInput(requiresVisibleWindow: false)
    guard let surface else {
      interpretKeyEvents([event])
      return
    }
    // Guarded: an unconditional write invalidates every observer of the bridge
    // state on every keystroke, key repeat included.
    if bridge.state.bellCount != 0 {
      bridge.state.bellCount = 0
    }
    let (translationEvent, translationMods) = translationState(event, surface: surface)
    let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
    keyTextAccumulator = []
    defer { keyTextAccumulator = nil }
    let markedTextBefore = markedText.length > 0
    let keyboardIdBefore = markedTextBefore ? nil : keyboardLayoutId()
    lastPerformKeyEvent = nil
    // Before the layout-switch return, so its key-up reaches keyUp(with:) and clears the suppression.
    LocalEventMonitor.keyPressed(event.keyCode, by: self)
    interpretKeyEvents([translationEvent])
    if !markedTextBefore, keyboardIdBefore != keyboardLayoutId() {
      keyboardLayoutChangeKeyUpSuppression = KeyboardLayoutChangeKeyUpSuppression(
        keyCode: event.keyCode,
        timestamp: event.timestamp
      )
      return
    }
    syncPreedit(clearIfNeeded: markedTextBefore)
    if let list = keyTextAccumulator, !list.isEmpty {
      for text in list {
        _ = sendKey(
          action: action,
          event: event,
          translationEvent: translationEvent,
          translationMods: translationMods,
          text: text,
          composing: false
        )
      }
    } else {
      _ = sendKey(
        action: action,
        event: event,
        translationEvent: translationEvent,
        translationMods: translationMods,
        text: ghosttyCharacters(translationEvent),
        composing: markedText.length > 0 || markedTextBefore
      )
    }
  }

  override func keyUp(with event: NSEvent) {
    if suppressKeyboardLayoutChangeKeyUp(event) { return }
    sendKey(action: GHOSTTY_ACTION_RELEASE, event: event)
  }

  override func flagsChanged(with event: NSEvent) {
    guard surface != nil, !hasMarkedText(), let action = Self.modifierAction(for: event) else { return }
    // Caps Lock latches rather than being held, so it never makes this surface a release holder.
    if action == GHOSTTY_ACTION_PRESS, event.keyCode != Self.capsLockKeyCode {
      LocalEventMonitor.modifierPressed(by: self)
    }
    sendKey(action: action, event: event)
  }

  // Press or release for a modifier key event; nil for keys that are not modifiers.
  static func modifierAction(for event: NSEvent) -> ghostty_input_action_e? {
    guard let masks = modifierMasks(keyCode: event.keyCode) else { return nil }
    guard (ghosttyMods(event.modifierFlags).rawValue & masks.mod) != 0 else { return GHOSTTY_ACTION_RELEASE }
    // The shared flag stays set while the other side is held, so prefer this key's side bit.
    let rawFlags = event.modifierFlags.rawValue
    let sidePressed = rawFlags & UInt(masks.side) != 0
    let hasSideBits = sidePressed || rawFlags & UInt(masks.otherSide) != 0
    return sidePressed || !hasSideBits ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
  }

  private static let capsLockKeyCode: UInt16 = 0x39

  private struct ModifierKeyMasks {
    let mod: UInt32
    let side: Int32
    let otherSide: Int32
  }

  private static func modifierMasks(keyCode: UInt16) -> ModifierKeyMasks? {
    switch keyCode {
    case capsLockKeyCode: ModifierKeyMasks(mod: GHOSTTY_MODS_CAPS.rawValue, side: 0, otherSide: 0)
    case 0x38:
      ModifierKeyMasks(
        mod: GHOSTTY_MODS_SHIFT.rawValue, side: NX_DEVICELSHIFTKEYMASK, otherSide: NX_DEVICERSHIFTKEYMASK)
    case 0x3C:
      ModifierKeyMasks(
        mod: GHOSTTY_MODS_SHIFT.rawValue, side: NX_DEVICERSHIFTKEYMASK, otherSide: NX_DEVICELSHIFTKEYMASK)
    case 0x3B:
      ModifierKeyMasks(mod: GHOSTTY_MODS_CTRL.rawValue, side: NX_DEVICELCTLKEYMASK, otherSide: NX_DEVICERCTLKEYMASK)
    case 0x3E:
      ModifierKeyMasks(mod: GHOSTTY_MODS_CTRL.rawValue, side: NX_DEVICERCTLKEYMASK, otherSide: NX_DEVICELCTLKEYMASK)
    case 0x3A:
      ModifierKeyMasks(mod: GHOSTTY_MODS_ALT.rawValue, side: NX_DEVICELALTKEYMASK, otherSide: NX_DEVICERALTKEYMASK)
    case 0x3D:
      ModifierKeyMasks(mod: GHOSTTY_MODS_ALT.rawValue, side: NX_DEVICERALTKEYMASK, otherSide: NX_DEVICELALTKEYMASK)
    case 0x37:
      ModifierKeyMasks(mod: GHOSTTY_MODS_SUPER.rawValue, side: NX_DEVICELCMDKEYMASK, otherSide: NX_DEVICERCMDKEYMASK)
    case 0x36:
      ModifierKeyMasks(mod: GHOSTTY_MODS_SUPER.rawValue, side: NX_DEVICERCMDKEYMASK, otherSide: NX_DEVICELCMDKEYMASK)
    default: nil
    }
  }

  override func mouseMoved(with event: NSEvent) {
    // AppKit sends no mouseEntered to a view mounted under a still pointer.
    LocalEventMonitor.pointerEntered(self)
    sendMousePosition(event)
    if let window, window.isKeyWindow, !focused, runtime.focusFollowsMouse() {
      requestFocus()
    }
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    LocalEventMonitor.pointerEntered(self)
    sendMousePosition(event)
  }

  override func mouseExited(with event: NSEvent) {
    LocalEventMonitor.pointerExited(self)
    if NSEvent.pressedMouseButtons != 0 {
      return
    }
    guard let surface else { return }
    let mods = Self.ghosttyMods(event.modifierFlags)
    ghostty_surface_mouse_pos(surface, -1, -1, mods)
  }

  override func mouseDown(with event: NSEvent) {
    healOcclusionFromUserInput(requiresVisibleWindow: true)
    forwardedLeftPressNumber = event.eventNumber
    sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
  }

  override func mouseUp(with event: NSEvent) {
    if forwardedLeftPressNumber == event.eventNumber {
      forwardedLeftPressNumber = nil
      sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    } else if let forwardedLeftPressNumber {
      // Keep the press pending so its real release still pairs.
      surfaceLogger.debug("Skipped left release \(event.eventNumber) unpaired with press \(forwardedLeftPressNumber).")
    }
    prevPressureStage = 0
    if let surface {
      ghostty_surface_mouse_pressure(surface, 0, 0)
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    guard let surface else {
      super.rightMouseDown(with: event)
      return
    }
    let mods = Self.ghosttyMods(event.modifierFlags)
    if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods) {
      return
    }
    super.rightMouseDown(with: event)
  }

  override func rightMouseUp(with event: NSEvent) {
    guard let surface else {
      super.rightMouseUp(with: event)
      return
    }
    let mods = Self.ghosttyMods(event.modifierFlags)
    if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods) {
      return
    }
    super.rightMouseUp(with: event)
  }

  override func otherMouseDown(with event: NSEvent) {
    sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: Self.ghosttyMouseButton(from: event.buttonNumber))
  }

  override func otherMouseUp(with event: NSEvent) {
    sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: Self.ghosttyMouseButton(from: event.buttonNumber))
  }

  private static func ghosttyMouseButton(from buttonNumber: Int) -> ghostty_input_mouse_button_e {
    switch buttonNumber {
    case 0: GHOSTTY_MOUSE_LEFT
    case 1: GHOSTTY_MOUSE_RIGHT
    case 2: GHOSTTY_MOUSE_MIDDLE
    case 3: GHOSTTY_MOUSE_EIGHT
    case 4: GHOSTTY_MOUSE_NINE
    case 5: GHOSTTY_MOUSE_SIX
    case 6: GHOSTTY_MOUSE_SEVEN
    case 7: GHOSTTY_MOUSE_FOUR
    case 8: GHOSTTY_MOUSE_FIVE
    case 9: GHOSTTY_MOUSE_TEN
    case 10: GHOSTTY_MOUSE_ELEVEN
    default: GHOSTTY_MOUSE_UNKNOWN
    }
  }

  override func mouseDragged(with event: NSEvent) {
    sendMousePosition(event)
  }

  override func rightMouseDragged(with event: NSEvent) {
    sendMousePosition(event)
  }

  override func otherMouseDragged(with event: NSEvent) {
    sendMousePosition(event)
  }

  override func scrollWheel(with event: NSEvent) {
    healOcclusionFromUserInput(requiresVisibleWindow: true)
    guard let surface else { return }
    var scrollX = event.scrollingDeltaX
    var scrollY = event.scrollingDeltaY
    if event.hasPreciseScrollingDeltas {
      scrollX *= 2
      scrollY *= 2
    }
    ghostty_surface_mouse_scroll(surface, scrollX, scrollY, scrollMods(for: event))
  }

  override func pressureChange(with event: NSEvent) {
    guard let surface else { return }
    ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    guard prevPressureStage < 2 else { return }
    prevPressureStage = event.stage
    guard event.stage == 2 else { return }
    guard UserDefaults.standard.bool(forKey: "com.apple.trackpad.forceClick") else { return }
    quickLook(with: event)
  }

  override func quickLook(with event: NSEvent) {
    guard let surface else { return super.quickLook(with: event) }
    var text = ghostty_text_s()
    guard ghostty_surface_quicklook_word(surface, &text) else { return super.quickLook(with: event) }
    defer { ghostty_surface_free_text(surface, &text) }
    guard text.text_len > 0 else { return super.quickLook(with: event) }

    var attributes: [NSAttributedString.Key: Any] = [:]
    if let fontRaw = ghostty_surface_quicklook_font(surface) {
      let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
      attributes[.font] = font.takeUnretainedValue()
      font.release()
    }

    let str = NSAttributedString(string: String(cString: text.text), attributes: attributes)
    let point = NSPoint(x: text.tl_px_x, y: frame.size.height - text.tl_px_y)
    showDefinition(for: str, at: point)
  }

  private func handleMonitoredLeftMouseDown(_ event: NSEvent) -> NSEvent? {
    // A press whose release never arrived must not stay held in Ghostty past the next click.
    if forwardedLeftPressNumber != nil {
      forwardedLeftPressNumber = nil
      sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }
    guard let window, window.firstResponder !== self else { return event }
    // App and window already active: this click only transfers split focus, so consume it
    // rather than forward a press to the terminal.
    if NSApp.isActive, window.isKeyWindow {
      // Only consume when focus actually transfers; otherwise forward so the click isn't lost.
      guard window.makeFirstResponder(self) else { return event }
      return nil
    }
    window.makeFirstResponder(self)
    return event
  }

  func updateSurfaceSize(contentSize: CGSize? = nil) {
    guard let surface else { return }
    // Off-window backing conversion is 1x; re-measuring a detached view would
    // halve the applied size and poison the hibernation freeze.
    guard window != nil || !hasBeenInWindow else { return }
    let backingSize = convertToBacking(contentSize ?? bounds.size)
    let currentSize = ghostty_surface_size(surface)
    let decision = ResizePolicy.decision(
      backingSize: backingSize,
      lastAppliedBackingSize: lastAppliedBackingSize,
      cellWidth: Int(currentSize.cell_width_px),
      cellHeight: Int(currentSize.cell_height_px)
    )
    guard decision == .apply else { return }
    lastAppliedBackingSize = backingSize
    ghostty_surface_set_size(
      surface,
      UInt32(max(1, Int(backingSize.width.rounded(.down)))),
      UInt32(max(1, Int(backingSize.height.rounded(.down))))
    )
  }

  enum ResizePolicy {
    enum Decision: Equatable {
      case skipUnchanged
      case apply
      case rejectDegenerate
    }

    // Sizes too small for a usable grid are rejected, not remembered; unknown cell
    // metrics (pre-first-render) always apply so Ghostty can derive them.
    static func decision(
      backingSize: CGSize,
      lastAppliedBackingSize: CGSize,
      cellWidth: Int,
      cellHeight: Int
    ) -> Decision {
      guard backingSize != lastAppliedBackingSize else { return .skipUnchanged }
      guard cellWidth > 0, cellHeight > 0 else { return .apply }
      let columns = max(1, Int(backingSize.width.rounded(.down))) / cellWidth
      let rows = max(1, Int(backingSize.height.rounded(.down))) / cellHeight
      guard columns >= 5, rows >= 2 else { return .rejectDegenerate }
      return .apply
    }
  }

  func updateCellSize(width: UInt32, height: UInt32) {
    cellSize = CGSize(width: CGFloat(width), height: CGFloat(height))
    scrollWrapper?.updateSurfaceSize()
  }

  func updateScrollbar(total: UInt64, offset: UInt64, length: UInt64) {
    lastScrollbar = ScrollbarState(total: total, offset: offset, length: length)
    scrollWrapper?.updateScrollbar(total: total, offset: offset, length: length)
  }

  func currentCellSize() -> CGSize {
    cellSize
  }

  /// The grid this surface last actually rendered at, for hibernation freeze;
  /// nil once the core is gone or while the size is still unknown.
  func captureFrozenGrid() -> FrozenGrid? {
    guard let surface else { return nil }
    let size = ghostty_surface_size(surface)
    // The stored fontSize is creation-time only; zoom lives in the core.
    let liveFontSize = ghostty_surface_font_size(surface)
    return FrozenGrid.from(
      backingSize: lastAppliedBackingSize,
      columns: Int(size.columns),
      rows: Int(size.rows),
      scale: appliedContentScale,
      fontSize: liveFontSize == 0 ? nil : liveFontSize
    )
  }

  func shouldShowScrollbar() -> Bool {
    runtime.shouldShowScrollbar()
  }

  func scrollbarAppearanceName() -> NSAppearance.Name {
    runtime.scrollbarAppearanceName()
  }

  func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
    let newCursor = cursor(for: shape)
    guard let newCursor else { return }
    guard newCursor != currentCursor else { return }
    currentCursor = newCursor
    window?.invalidateCursorRects(for: self)
  }

  private func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor? {
    if let cursor = Self.mouseCursorMap[shape] {
      return cursor
    }
    if Self.mouseResizeLeftRightShapes.contains(shape) {
      return .resizeLeftRight
    }
    if Self.mouseResizeUpDownShapes.contains(shape) {
      return .resizeUpDown
    }
    return nil
  }

  func setMouseVisibility(_ visible: Bool) {
    NSCursor.setHiddenUntilMouseMoves(!visible)
  }

  private func createSurface() {
    guard let app = runtime.app else { return }
    var config = ghostty_surface_config_new()
    config.userdata = Unmanaged.passUnretained(bridge).toOpaque()
    config.platform_tag = GHOSTTY_PLATFORM_MACOS
    config.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(
        nsview: Unmanaged.passUnretained(self).toOpaque()
      ))
    config.scale_factor = backingScaleFactor()
    config.font_size = fontSize
    config.working_directory = workingDirectoryCString.map { UnsafePointer($0) }
    config.command = commandCString.map { UnsafePointer($0) }
    config.initial_input = initialInputCString.map { UnsafePointer($0) }
    config.context = context
    config.disable_shell_integration = disableShellIntegration
    // Ghostty copies env vars into its arena allocator, so
    // the C strings only need to live through this call.
    var envVars = environmentVariables.map { key, value in
      ghostty_env_var_s(
        key: key.withCString { strdup($0)! },
        value: value.withCString { strdup($0)! }
      )
    }
    defer {
      for envVar in envVars {
        free(.init(mutating: envVar.key))
        free(.init(mutating: envVar.value))
      }
    }
    // Wrapper argv C strings must also outlive the surface_new call.
    let wrapperCStrings: [UnsafePointer<CChar>?] = commandWrapper.map { arg in
      UnsafePointer(arg.withCString { strdup($0)! })
    }
    defer {
      for ptr in wrapperCStrings {
        free(UnsafeMutablePointer(mutating: ptr))
      }
    }
    envVars.withUnsafeMutableBufferPointer { envBuffer in
      if let baseAddress = envBuffer.baseAddress, !envBuffer.isEmpty {
        config.env_vars = baseAddress
        config.env_var_count = envBuffer.count
      }
      wrapperCStrings.withUnsafeBufferPointer { wrapperBuffer in
        if let baseAddress = wrapperBuffer.baseAddress, !wrapperBuffer.isEmpty {
          config.command_wrapper = baseAddress
          config.command_wrapper_count = wrapperBuffer.count
        }
        surface = ghostty_surface_new(app, &config)
      }
    }
    bridge.surface = surface
    lastOcclusion = nil
    lastSurfaceFocus = nil
    // A new Ghostty surface defaults to focused (solid cursor), but `focused`
    // starts false, so `focusDidChange(false)` would dedup and never clear it,
    // leaving every restored pane's cursor solid. Start unfocused to agree with
    // `focused`; the focus flow sets the truly focused pane solid.
    setSurfaceFocus(false)
    updateSurfaceSize()
  }

  private func updateContentScale() {
    guard let surface else { return }
    // A detached-but-previously-mounted view has no better scale than the one
    // already applied; re-pushing the creation scale would churn the renderer.
    guard window != nil || !hasBeenInWindow else { return }
    let scale = backingScaleFactor()
    appliedContentScale = scale
    ghostty_surface_set_content_scale(surface, scale, scale)
  }

  private func backingScaleFactor() -> Double {
    if let window {
      return window.backingScaleFactor
    }
    return initialScale
  }

  func setOcclusion(_ visible: Bool) {
    guard let surface else { return }
    if lastOcclusion == visible {
      return
    }
    lastOcclusion = visible
    surfaceLogger.info("Surface \(self.id) occlusion -> \(visible ? "visible" : "occluded")")
    ghostty_surface_set_occlusion(surface, visible)
  }

  private func healOcclusionFromUserInput(requiresVisibleWindow: Bool) {
    guard let window else { return }
    let shouldHeal = Self.shouldHealOcclusion(
      lastOcclusion: lastOcclusion,
      windowIsKey: window.isKeyWindow,
      windowIsVisible: window.occlusionState.contains(.visible),
      requiresVisibleWindow: requiresVisibleWindow
    )
    guard shouldHeal else {
      if lastOcclusion == false {
        surfaceLogger.debug(
          "Occlusion heal skipped for surface \(self.id): window not key or not reported visible."
        )
      }
      return
    }
    let occlusionState = window.occlusionState.rawValue
    surfaceLogger.debug(
      "Surface \(self.id) received user input while occluded (occlusionState: \(occlusionState)); requesting heal."
    )
    onOcclusionHeal?(window.isKeyWindow, window.occlusionState.contains(.visible))
  }

  /// A key press requests a heal even when the window server reports covered;
  /// the request is advisory, the state defers to the window's fresh readings.
  /// Pointer events also require a visible report up front.
  static func shouldHealOcclusion(
    lastOcclusion: Bool?,
    windowIsKey: Bool,
    windowIsVisible: Bool,
    requiresVisibleWindow: Bool
  ) -> Bool {
    guard lastOcclusion == false, windowIsKey else { return false }
    return !requiresVisibleWindow || windowIsVisible
  }

  private func setSurfaceFocus(_ focused: Bool) {
    guard let surface else { return }
    if lastSurfaceFocus == focused {
      return
    }
    lastSurfaceFocus = focused
    ghostty_surface_set_focus(surface, focused)
  }

  func requestFocus() {
    Self.moveFocus(to: self)
  }

  static func moveFocus(
    to view: GhosttySurfaceView,
    from previous: GhosttySurfaceView? = nil,
    delay: TimeInterval? = nil
  ) {
    let maxDelay: TimeInterval = 0.5
    let currentDelay = delay ?? 0
    guard currentDelay < maxDelay else { return }
    let nextDelay: TimeInterval = if let delay { delay * 2 } else { 0.05 }
    Task { @MainActor in
      if let delay {
        try? await ContinuousClock().sleep(for: .seconds(delay))
      }
      guard let window = view.window else {
        moveFocus(to: view, from: previous, delay: nextDelay)
        return
      }
      if let previous, previous !== view {
        _ = previous.resignFirstResponder()
      }
      window.makeFirstResponder(view)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    guard let surface else { return false }
    // `focused` is a cached flag updated via `becomeFirstResponder` /
    // `resignFirstResponder`, but AppKit calls `performKeyEquivalent`
    // on every view in the window, including this one when the
    // sidebar `List` has been clicked but didn't formally demote us
    // out of the responder chain. Gate strictly on AppKit's current
    // answer so a click on the sidebar lets ⌘⌫ reach the main menu.
    guard focused, window?.firstResponder === self else { return false }

    // Image-only Cmd+V routes to Claude's native Ctrl+V paste before binding
    // resolution, intentionally overriding the default `super+v=paste_from_clipboard`
    // binding (which would otherwise drop the image).
    if routeCommandPasteToNativeImagePasteIfNeeded(event) {
      return true
    }

    if let bindingFlags = bindingFlags(for: event, surface: surface) {
      // Forward to the menu only when the chord resolves to an app-owned item, so Ghostty-only
      // shortcuts like `⌘⇧,` aren't eaten by AppKit's menu-matching quirks. A chord with no
      // forwardable item (e.g. `⌘⌥H` Hide Others vs a `goto_split` binding) falls through to
      // Ghostty so the terminal binding wins.
      if shouldAttemptMenu(for: bindingFlags),
        // Sidebar-only chords stay with the terminal (`⌘⌫` deletes the line).
        !isTerminalUnreachableChord(event),
        let menu = NSApp.mainMenu,
        let item = Self.forwardableMenuItem(for: event, in: menu),
        Self.dispatchForwardableChord(item, for: event, in: menu)
      {
        return true
      }
      keyDown(with: event)
      return true
    }

    // A sidebar-only chord Ghostty doesn't bind must still reach the shell, not its disabled menu item.
    if isTerminalUnreachableChord(event) {
      keyDown(with: event)
      return true
    }

    guard let equivalent = equivalentKey(for: event) else { return false }

    guard
      let finalEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: event.locationInWindow,
        modifierFlags: event.modifierFlags,
        timestamp: event.timestamp,
        windowNumber: event.windowNumber,
        context: nil,
        characters: equivalent,
        charactersIgnoringModifiers: equivalent,
        isARepeat: event.isARepeat,
        keyCode: event.keyCode
      )
    else {
      return false
    }
    keyDown(with: finalEvent)
    return true
  }

  private func routeCommandPasteToNativeImagePasteIfNeeded(_ event: NSEvent) -> Bool {
    guard
      Self.shouldRouteCommandPasteToNativeImagePaste(
        event: event,
        pasteboardTypes: NSPasteboard.general.types,
        imagePasteAgents: imagePasteAgents,
        keySequenceActive: bridge.state.keySequenceActive == true,
        keyTableDepth: bridge.state.keyTableDepth
      )
    else {
      return false
    }
    guard let nativeEvent = Self.nativeImagePasteEvent(from: event) else {
      surfaceLogger.error("Cmd+V image paste matched but Ctrl+V synthesis returned nil; falling back to default paste.")
      return false
    }
    keyDown(with: nativeEvent)
    // The real key-up carries the layout's keyCode for V, so pair the release with it.
    if LocalEventMonitor.takeKeyHolder(for: nativeEvent.keyCode) === self {
      LocalEventMonitor.keyPressed(event.keyCode, by: self)
    }
    return true
  }

  // `pasteboardTypes` is an autoclosure so the cross-process pasteboard read only
  // happens once the cheap local gates pass, not on every Cmd chord.
  static func shouldRouteCommandPasteToNativeImagePaste(
    event: NSEvent,
    pasteboardTypes: @autoclosure () -> [NSPasteboard.PasteboardType]?,
    imagePasteAgents: Set<SkillAgent>,
    keySequenceActive: Bool,
    keyTableDepth: Int
  ) -> Bool {
    guard event.type == .keyDown else { return false }
    guard !keySequenceActive, keyTableDepth == 0 else { return false }
    guard imagePasteAgents.contains(.claude) else { return false }
    guard isExactCommandV(event) else { return false }
    guard let types = pasteboardTypes(), types.contains(where: isImagePasteboardType) else { return false }
    return types.allSatisfy { !isTextOrFilePasteboardType($0) }
  }

  static func nativeImagePasteEvent(from event: NSEvent) -> NSEvent? {
    guard isExactCommandV(event) else { return nil }
    return NSEvent.keyEvent(
      with: .keyDown,
      location: event.locationInWindow,
      modifierFlags: .control,
      timestamp: event.timestamp,
      windowNumber: event.windowNumber,
      context: nil,
      characters: "v",
      charactersIgnoringModifiers: "v",
      isARepeat: event.isARepeat,
      keyCode: UInt16(kVK_ANSI_V)
    )
  }

  private static func isExactCommandV(_ event: NSEvent) -> Bool {
    let shortcutMask: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    return event.charactersIgnoringModifiers?.lowercased() == "v"
      && event.modifierFlags.intersection(shortcutMask) == [.command]
  }

  private static func isTextOrFilePasteboardType(_ type: NSPasteboard.PasteboardType) -> Bool {
    if [.string, .fileURL, .URL].contains(type) { return true }
    guard let uniformType = UTType(type.rawValue) else { return false }
    return uniformType.conforms(to: .text) || uniformType.conforms(to: .url)
  }

  private static func isImagePasteboardType(_ type: NSPasteboard.PasteboardType) -> Bool {
    guard let uniformType = UTType(type.rawValue) else { return false }
    return uniformType.conforms(to: .image)
  }

  private func bindingFlags(
    for event: NSEvent,
    surface: ghostty_surface_t
  ) -> ghostty_binding_flags_e? {
    var key = ghosttyKeyEvent(
      event,
      action: GHOSTTY_ACTION_PRESS,
      originalMods: event.modifierFlags,
      translationMods: event.modifierFlags
    )
    var flags = ghostty_binding_flags_e(0)
    let isBinding = (event.characters ?? "").withCString { ptr in
      key.text = ptr
      return ghostty_surface_key_is_binding(surface, key, &flags)
    }
    return isBinding ? flags : nil
  }

  private func equivalentKey(for event: NSEvent) -> String? {
    switch event.charactersIgnoringModifiers {
    case "\r":
      guard event.modifierFlags.contains(.control) else { return nil }
      return "\r"
    case "/":
      guard event.modifierFlags.contains(.control) else { return nil }
      guard event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return nil }
      return "_"
    default:
      if event.timestamp == 0 { return nil }
      if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
        lastPerformKeyEvent = nil
        return nil
      }
      if let lastPerformKeyEvent {
        self.lastPerformKeyEvent = nil
        if lastPerformKeyEvent == event.timestamp {
          return event.characters ?? ""
        }
      }
      lastPerformKeyEvent = event.timestamp
      return nil
    }
  }

  override func doCommand(by selector: Selector) {
    if let lastPerformKeyEvent,
      let current = NSApp.currentEvent,
      lastPerformKeyEvent == current.timestamp
    {
      NSApp.sendEvent(current)
      return
    }
    switch selector {
    case #selector(moveToBeginningOfDocument(_:)):
      performBindingAction("scroll_to_top")
    case #selector(moveToEndOfDocument(_:)):
      performBindingAction("scroll_to_bottom")
    default:
      break
    }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    switch event.type {
    case .rightMouseDown:
      break
    case .leftMouseDown:
      if !event.modifierFlags.contains(.control) {
        return nil
      }
      guard let surface else { return nil }
      if ghostty_surface_mouse_captured(surface) {
        return nil
      }
      let mods = Self.ghosttyMods(event.modifierFlags)
      _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods)
    default:
      return nil
    }

    guard let surface else { return nil }
    if ghostty_surface_mouse_captured(surface) {
      return nil
    }

    let menu = NSMenu()
    if ghostty_surface_has_selection(surface) {
      menu.addItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""))
    }
    menu.addItem(NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(
      menuItem(
        title: "Split Right",
        action: #selector(splitRight(_:)),
        symbol: "rectangle.righthalf.inset.filled"
      ))
    menu.addItem(
      menuItem(
        title: "Split Left",
        action: #selector(splitLeft(_:)),
        symbol: "rectangle.leadinghalf.inset.filled"
      ))
    menu.addItem(
      menuItem(
        title: "Split Down",
        action: #selector(splitDown(_:)),
        symbol: "rectangle.bottomhalf.inset.filled"
      ))
    menu.addItem(
      menuItem(
        title: "Split Up",
        action: #selector(splitUp(_:)),
        symbol: "rectangle.tophalf.inset.filled"
      ))
    menu.addItem(.separator())
    menu.addItem(
      menuItem(
        title: "Reset Terminal",
        action: #selector(resetTerminal(_:)),
        symbol: "arrow.trianglehead.2.clockwise"
      ))
    menu.addItem(.separator())
    menu.addItem(
      menuItem(
        title: "Change Title...",
        action: #selector(changeTitle(_:)),
        symbol: "pencil.line"
      ))
    return menu
  }

  private func menuItem(title: String, action: Selector, symbol: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    return item
  }

  @IBAction func splitRight(_ sender: Any?) {
    _ = bridge.onSplitAction?(.newSplit(direction: .right))
  }

  @IBAction func splitLeft(_ sender: Any?) {
    _ = bridge.onSplitAction?(.newSplit(direction: .left))
  }

  @IBAction func splitDown(_ sender: Any?) {
    _ = bridge.onSplitAction?(.newSplit(direction: .down))
  }

  @IBAction func splitUp(_ sender: Any?) {
    _ = bridge.onSplitAction?(.newSplit(direction: .top))
  }

  @IBAction func resetTerminal(_ sender: Any?) {
    performBindingAction("reset")
  }

  @IBAction func changeTitle(_ sender: Any?) {
    performBindingAction("prompt_surface_title")
  }

  /// macOS app/window-management actions the user cannot remap from Settings → Shortcuts.
  /// We skip these when matching so a colliding terminal binding wins instead of firing both.
  static let systemManagedMenuActions: Set<Selector> = [
    #selector(NSApplication.hide(_:)),
    #selector(NSApplication.hideOtherApplications(_:)),
    #selector(NSApplication.unhideAllApplications(_:)),
    #selector(NSWindow.performMiniaturize(_:)),
    #selector(NSWindow.performZoom(_:)),
    #selector(NSWindow.toggleFullScreen(_:)),
    #selector(NSApplication.arrangeInFront(_:)),
  ]

  /// True when `item` triggers one of `systemManagedMenuActions`.
  static func isSystemManagedMenuItem(_ item: NSMenuItem) -> Bool {
    guard let action = item.action else { return false }
    return systemManagedMenuActions.contains(action)
  }

  /// True when `item`'s key equivalent and modifier mask match `event` exactly. An exact
  /// modifier match keeps a shortcut like `⌘,` (Settings) from eating `⌘⇧,` (Ghostty's
  /// `reload_config`). An uppercase `keyEquivalent` encodes shift implicitly (AppKit
  /// convention), so we fold that into the item's effective mask before comparing.
  static func menuItem(_ item: NSMenuItem, matches event: NSEvent) -> Bool {
    guard !item.keyEquivalent.isEmpty else { return false }
    guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else { return false }
    let itemKey = item.keyEquivalent
    guard itemKey.lowercased() == characters else { return false }
    let shortcutMask: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    var itemMask = item.keyEquivalentModifierMask.intersection(shortcutMask)
    if itemKey != itemKey.lowercased() { itemMask.insert(.shift) }
    return itemMask == event.modifierFlags.intersection(shortcutMask)
  }

  /// Recursively walks the main menu for the first app-owned item matching `event`, returning
  /// it so the caller knows the chord resolves to an app shortcut worth forwarding. Non-remappable
  /// macOS built-ins are skipped so a terminal binding wins over them instead of being suppressed.
  static func forwardableMenuItem(for event: NSEvent, in menu: NSMenu) -> NSMenuItem? {
    for item in menu.items {
      if let submenu = item.submenu, let match = forwardableMenuItem(for: event, in: submenu) { return match }
      guard menuItem(item, matches: event), !isSystemManagedMenuItem(item) else { continue }
      return item
    }
    return nil
  }

  /// True when `event`'s chord also matches a non-remappable macOS built-in (Hide, Minimize, ...),
  /// even when an app-owned item shares the same chord (e.g. a custom `close_surface` on `⌘M`).
  static func menuHasSystemManagedConflict(for event: NSEvent, in menu: NSMenu) -> Bool {
    for item in menu.items {
      if let submenu = item.submenu, menuHasSystemManagedConflict(for: event, in: submenu) { return true }
      if isSystemManagedMenuItem(item), menuItem(item, matches: event) { return true }
    }
    return false
  }

  /// Dispatches the resolved app-owned `item` for `event`. When the chord also matches a
  /// non-remappable built-in, fires `item` directly so the built-in can't fire too and the app
  /// action's own side effects still run (e.g. `close_surface`'s explicit-close bookkeeping, which
  /// a fall-through to Ghostty would skip and so reattach a zmx surface instead of closing it).
  /// Otherwise uses the native key-equivalent path, which drives SwiftUI command items like `⌘W`.
  static func dispatchForwardableChord(_ item: NSMenuItem, for event: NSEvent, in menu: NSMenu) -> Bool {
    guard menuHasSystemManagedConflict(for: event, in: menu) else { return menu.performKeyEquivalent(with: event) }
    return performMenuItem(item)
  }

  /// Fires `item`'s action through the responder chain so only that item runs, never a built-in
  /// that shares the chord. `NSApp.sendAction` is the same dispatch the native key-equivalent path
  /// ends in, so SwiftUI command items fire without `update()` rebuilding and detaching the menu.
  /// Returns false when the item is disabled or unhandled so the caller falls back to Ghostty.
  @discardableResult
  static func performMenuItem(_ item: NSMenuItem) -> Bool {
    guard item.isEnabled, let action = item.action else { return false }
    return NSApp.sendAction(action, to: item.target, from: item)
  }

  private func isTerminalUnreachableChord(_ event: NSEvent) -> Bool {
    AppShortcuts.isTerminalUnreachableChord(event, overrides: settingsFile.global.shortcutOverrides)
  }

  private func shouldAttemptMenu(for flags: ghostty_binding_flags_e) -> Bool {
    if bridge.state.keySequenceActive == true { return false }
    if bridge.state.keyTableDepth > 0 { return false }
    let raw = flags.rawValue
    let isAll = (raw & GHOSTTY_BINDING_FLAGS_ALL.rawValue) != 0
    let isPerformable = (raw & GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue) != 0
    let isConsumed = (raw & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue) != 0
    return !isAll && !isPerformable && isConsumed
  }

  @IBAction func copy(_ sender: Any?) {
    performBindingAction("copy_to_clipboard")
  }

  @IBAction func paste(_ sender: Any?) {
    performBindingAction("paste_from_clipboard")
  }

  @IBAction func pasteSelection(_ sender: Any?) {
    performBindingAction("paste_from_selection")
  }

  @IBAction override func selectAll(_ sender: Any?) {
    performBindingAction("select_all")
  }

  @discardableResult
  private func sendKey(
    action: ghostty_input_action_e,
    event: NSEvent,
    translationEvent: NSEvent? = nil,
    translationMods: NSEvent.ModifierFlags? = nil,
    text: String? = nil,
    composing: Bool = false
  ) -> Bool {
    guard let surface else { return false }
    let resolvedEvent: NSEvent
    let resolvedMods: NSEvent.ModifierFlags
    if let translationEvent, let translationMods {
      resolvedEvent = translationEvent
      resolvedMods = translationMods
    } else {
      (resolvedEvent, resolvedMods) = translationState(event, surface: surface)
    }
    var key = ghosttyKeyEvent(
      resolvedEvent,
      action: action,
      originalMods: event.modifierFlags,
      translationMods: resolvedMods,
      composing: composing
    )
    let finalText = text ?? ghosttyCharacters(resolvedEvent)
    if let finalText, !finalText.isEmpty,
      let codepoint = finalText.utf8.first, codepoint >= 0x20
    {
      return finalText.withCString { ptr in
        key.text = ptr
        return ghostty_surface_key(surface, key)
      }
    }
    key.text = nil
    return ghostty_surface_key(surface, key)
  }

  func performBindingAction(_ action: String) {
    #if DEBUG
      recordedBindingActions.append(action)
    #endif
    guard let surface else { return }
    _ = action.withCString { ptr in
      ghostty_surface_binding_action(surface, ptr, UInt(action.lengthOfBytes(using: .utf8)))
    }
  }

  /// Flip the surface into read-only and mirror the state up-front so tests
  /// observe it without Ghostty's `GHOSTTY_ACTION_READONLY` callback. Idempotent
  /// against a stale mirror because Ghostty only exposes a toggle binding; we
  /// avoid an UN-freeze API to keep the toggle from silently flipping ON.
  func enableReadOnly() {
    guard bridge.state.readOnly != GHOSTTY_READONLY_ON else { return }
    bridge.state.readOnly = GHOSTTY_READONLY_ON
    performBindingAction("toggle_readonly")
  }

  #if DEBUG
    /// Records every `performBindingAction` call so tests can assert the
    /// binding was actually invoked (the C surface is nil under xctest).
    var recordedBindingActions: [String] = []

    /// Read-only responder-focus seam for the #757 activity tests.
    var isFocusedForTesting: Bool { focused }
  #endif

  private func translationState(_ event: NSEvent, surface: ghostty_surface_t) -> (
    NSEvent, NSEvent.ModifierFlags
  ) {
    // `characters`-family APIs throw on non-key events, so skip translation for a
    // modifier-only event (otherwise a bare Cmd aborts the send before Ghostty sees it).
    guard event.type == .keyDown || event.type == .keyUp else {
      return (event, event.modifierFlags)
    }
    let translatedModsGhostty = ghostty_surface_key_translation_mods(
      surface, Self.ghosttyMods(event.modifierFlags))
    let translatedMods = appKitMods(translatedModsGhostty)
    var resolved = event.modifierFlags
    for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
      if translatedMods.contains(flag) {
        resolved.insert(flag)
      } else {
        resolved.remove(flag)
      }
    }
    if resolved == event.modifierFlags {
      return (event, resolved)
    }
    let translatedEvent =
      NSEvent.keyEvent(
        with: event.type,
        location: event.locationInWindow,
        modifierFlags: resolved,
        timestamp: event.timestamp,
        windowNumber: event.windowNumber,
        context: nil,
        characters: event.characters(byApplyingModifiers: resolved) ?? "",
        charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
        isARepeat: event.isARepeat,
        keyCode: event.keyCode
      ) ?? event
    return (translatedEvent, resolved)
  }

  private func ghosttyKeyEvent(
    _ event: NSEvent,
    action: ghostty_input_action_e,
    originalMods: NSEvent.ModifierFlags,
    translationMods: NSEvent.ModifierFlags,
    composing: Bool = false
  ) -> ghostty_input_key_s {
    var keyEvent: ghostty_input_key_s = .init()
    keyEvent.action = action
    keyEvent.keycode = UInt32(event.keyCode)
    keyEvent.text = nil
    keyEvent.composing = composing
    keyEvent.mods = Self.ghosttyMods(originalMods)
    keyEvent.consumed_mods = Self.ghosttyMods(translationMods.subtracting([.control, .command]))
    keyEvent.unshifted_codepoint = 0
    if event.type == .keyDown || event.type == .keyUp {
      if let chars = event.characters(byApplyingModifiers: []),
        let codepoint = chars.unicodeScalars.first
      {
        keyEvent.unshifted_codepoint = codepoint.value
      }
    }
    return keyEvent
  }

  private func suppressKeyboardLayoutChangeKeyUp(_ event: NSEvent) -> Bool {
    guard let suppression = keyboardLayoutChangeKeyUpSuppression else { return false }
    if suppression.isExpired(at: event.timestamp) {
      keyboardLayoutChangeKeyUpSuppression = nil
      return false
    }
    if suppression.suppresses(keyCode: event.keyCode, timestamp: event.timestamp) {
      keyboardLayoutChangeKeyUpSuppression = nil
      return true
    }
    return false
  }

  private func ghosttyCharacters(_ event: NSEvent) -> String? {
    // `characters` throws on non-key events; a bare modifier (flagsChanged) carries none.
    guard event.type == .keyDown || event.type == .keyUp else { return nil }
    guard let characters = event.characters else { return nil }
    if characters.count == 1,
      let scalar = characters.unicodeScalars.first
    {
      if scalar.value < 0x20 {
        return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
      }
      if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
        return nil
      }
    }
    return characters
  }

  private func syncPreedit(clearIfNeeded: Bool = true) {
    guard let surface else { return }
    if markedText.length > 0 {
      let str = markedText.string
      let len = str.utf8CString.count
      if len > 0 {
        markedText.string.withCString { ptr in
          ghostty_surface_preedit(surface, ptr, UInt(len - 1))
        }
      }
    } else if clearIfNeeded {
      ghostty_surface_preedit(surface, nil, 0)
    }
  }

  private func scrollMods(for event: NSEvent) -> ghostty_input_scroll_mods_t {
    var value: Int32 = 0
    if event.hasPreciseScrollingDeltas {
      value |= 0b0000_0001
    }
    let momentum: Int32
    switch event.momentumPhase {
    case .began:
      momentum = 1
    case .stationary:
      momentum = 2
    case .changed:
      momentum = 3
    case .ended:
      momentum = 4
    case .cancelled:
      momentum = 5
    case .mayBegin:
      momentum = 6
    default:
      momentum = 0
    }
    value |= (momentum << 1)
    return ghostty_input_scroll_mods_t(value)
  }

  private func keyboardLayoutId() -> String? {
    let sources = [
      TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
      TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
    ]

    for source in sources.compactMap({ $0 }) {
      guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
        continue
      }
      let value = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
      return value as String
    }

    return nil
  }

  private func sendMousePosition(_ event: NSEvent) {
    guard let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    let yPosition = bounds.height - point.y
    let mods = Self.ghosttyMods(event.modifierFlags)
    ghostty_surface_mouse_pos(surface, point.x, yPosition, mods)
  }

  private func sendMouseButton(
    _ event: NSEvent,
    state: ghostty_input_mouse_state_e,
    button: ghostty_input_mouse_button_e
  ) {
    guard let surface else { return }
    let mods = Self.ghosttyMods(event.modifierFlags)
    ghostty_surface_mouse_button(surface, state, button, mods)
  }

  private static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
    let rawFlags = flags.rawValue
    if (rawFlags & UInt(NX_DEVICERSHIFTKEYMASK)) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if (rawFlags & UInt(NX_DEVICERCTLKEYMASK)) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if (rawFlags & UInt(NX_DEVICERALTKEYMASK)) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if (rawFlags & UInt(NX_DEVICERCMDKEYMASK)) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
    return ghostty_input_mods_e(mods)
  }

  private func appKitMods(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if (mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0 { flags.insert(.shift) }
    if (mods.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0 { flags.insert(.control) }
    if (mods.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0 { flags.insert(.option) }
    if (mods.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0 { flags.insert(.command) }
    if (mods.rawValue & GHOSTTY_MODS_CAPS.rawValue) != 0 { flags.insert(.capsLock) }
    return flags
  }

}

extension GhosttySurfaceView {
  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard let types = sender.draggingPasteboard.types else { return [] }
    if Set(types).isDisjoint(with: Self.dropTypes) {
      return []
    }
    return .copy
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let pasteboard = sender.draggingPasteboard
    let content: String?
    if let url = pasteboard.string(forType: .URL) {
      content = NSPasteboard.ghosttyEscape(url)
    } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
      !urls.isEmpty
    {
      content = urls.map { NSPasteboard.ghosttyEscape($0.path) }.joined(separator: " ")
    } else if let str = pasteboard.string(forType: .string) {
      content = str
    } else {
      content = nil
    }

    guard let content else { return false }
    Task { @MainActor in
      self.insertText(content, replacementRange: NSRange(location: 0, length: 0))
    }
    return true
  }
}

extension GhosttySurfaceView {
  // One app-level monitor so per-event cost doesn't grow with the surface count.
  enum LocalEventMonitor {
    // Both installed once for the app's lifetime; never removed.
    private static var monitor: Any?
    private static var becomeActiveObserver: NSObjectProtocol?
    private(set) static weak var hoveredSurface: GhosttySurfaceView?
    // Surfaces that took a modifier press since all modifiers were last up.
    private static let modifierHolders = NSHashTable<GhosttySurfaceView>.weakObjects()
    // Latest surface to take each key down, so its key-up never reaches a different surface.
    private static let keyHolders = NSMapTable<NSNumber, GhosttySurfaceView>.strongToWeakObjects()

    static func installIfNeeded() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown, .flagsChanged]) { event in
        route(event)
      }
      guard monitor != nil else {
        surfaceLogger.error("Failed to install the surface event monitor.")
        return
      }
      // Key-ups released in another app never reach the monitor, so reconcile on return.
      becomeActiveObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { _ in
        MainActor.assumeIsolated {
          releaseKeys { !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
        }
      }
    }

    static func pointerEntered(_ surface: GhosttySurfaceView) {
      hoveredSurface = surface
    }

    static func pointerExited(_ surface: GhosttySurfaceView) {
      // AppKit can enter the next split before exiting this one.
      guard hoveredSurface === surface else { return }
      hoveredSurface = nil
    }

    static func modifierPressed(by surface: GhosttySurfaceView) {
      modifierHolders.add(surface)
    }

    static func surfaceClosed(_ surface: GhosttySurfaceView) {
      pointerExited(surface)
      modifierHolders.remove(surface)
      for key in heldKeys(where: { keyHolders.object(forKey: $0) === surface }) {
        keyHolders.removeObject(forKey: key)
      }
    }

    static func isModifierHolder(_ surface: GhosttySurfaceView) -> Bool {
      modifierHolders.contains(surface)
    }

    static func keyPressed(_ keyCode: UInt16, by surface: GhosttySurfaceView) {
      keyHolders.setObject(surface, forKey: NSNumber(value: keyCode))
    }

    // Each key-down pairs with one key-up, so reading the holder also clears it.
    static func takeKeyHolder(for keyCode: UInt16) -> GhosttySurfaceView? {
      let key = NSNumber(value: keyCode)
      let holder = keyHolders.object(forKey: key)
      keyHolders.removeObject(forKey: key)
      return holder
    }

    // Sends a key-up to the holder of every held key the predicate reports as released.
    static func releaseKeys(where isReleased: (UInt16) -> Bool) {
      for key in heldKeys(where: { isReleased($0.uint16Value) }) {
        guard let holder = takeKeyHolder(for: key.uint16Value) else { continue }
        guard let release = syntheticKeyUp(keyCode: key.uint16Value, in: holder) else {
          surfaceLogger.error("Failed to synthesize the key-up for key code \(key.uint16Value).")
          continue
        }
        holder.keyUp(with: release)
      }
    }

    // Snapshot first: the table can't be mutated while it is enumerated.
    private static func heldKeys(where matches: (NSNumber) -> Bool) -> [NSNumber] {
      var keys: [NSNumber] = []
      for case let key as NSNumber in keyHolders.keyEnumerator() where matches(key) {
        keys.append(key)
      }
      return keys
    }

    private static func syntheticKeyUp(keyCode: UInt16, in surface: GhosttySurfaceView) -> NSEvent? {
      NSEvent.keyEvent(
        with: .keyUp,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: surface.window?.windowNumber ?? 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: keyCode
      )
    }

    enum KeyUpAction<Surface: AnyObject> {
      case pass
      // Release in the holder; `consumesEvent` keeps AppKit from also delivering it to the responder.
      case release(holder: Surface, consumesEvent: Bool)
      case drop
    }

    // Pairs a key-up with the surface that took its key-down.
    static func keyUpAction<Surface: AnyObject>(
      isCommandChord: Bool,
      holder: Surface?,
      responderSurface: Surface?
    ) -> KeyUpAction<Surface> {
      // No holder means Ghostty never took the press, so a surface responder must not get a release.
      guard let holder else { return responderSurface == nil ? .pass : .drop }
      // AppKit never delivers a Cmd chord's keyUp to the responder, so hand it over here.
      if isCommandChord {
        return .release(holder: holder, consumesEvent: true)
      }
      if responderSurface === holder {
        return .pass
      }
      return .release(holder: holder, consumesEvent: responderSurface != nil)
    }

    private static func route(_ event: NSEvent) -> NSEvent? {
      switch event.type {
      case .keyUp:
        let holder = takeKeyHolder(for: event.keyCode)
        let action = keyUpAction(
          isCommandChord: event.modifierFlags.contains(.command),
          holder: holder,
          responderSurface: NSApp.keyWindow?.firstResponder as? GhosttySurfaceView
        )
        switch action {
        case .pass:
          return event
        case .release(let holder, let consumesEvent):
          // Ghostty's focus loss releases only the latest key, so the holder still needs this one.
          holder.keyUp(with: event)
          return consumesEvent ? nil : event
        case .drop:
          return nil
        }
      case .leftMouseDown:
        // Hit-test in window space from the frame view so titlebar controls win and scroll offsets apply once.
        let frameView = event.window?.contentView?.superview ?? event.window?.contentView
        guard let surface = frameView?.hitTest(event.locationInWindow) as? GhosttySurfaceView
        else { return event }
        return surface.handleMonitoredLeftMouseDown(event)
      case .flagsChanged:
        routeFlagsChanged(event)
        return event
      default:
        return event
      }
    }

    private static func routeFlagsChanged(_ event: NSEvent) {
      let targets = flagsChangedTargets(
        hovered: routableHoveredSurface,
        modifierHolders: modifierHolders.allObjects,
        isRelease: GhosttySurfaceView.modifierAction(for: event) == GHOSTTY_ACTION_RELEASE,
        keyResponder: NSApp.keyWindow?.firstResponder
      )
      for surface in targets {
        surface.flagsChanged(with: event)
      }
      guard event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command]) else { return }
      modifierHolders.removeAllObjects()
    }

    // Detached or hidden surfaces get no exit, so a tracked hover can be stale.
    private static var routableHoveredSurface: GhosttySurfaceView? {
      guard let hoveredSurface, hoveredSurface.window != nil, !hoveredSurface.isHiddenOrHasHiddenAncestor
      else { return nil }
      return hoveredSurface
    }

    // flagsChanged only reaches the key responder; also send it to the hover, and releases to every holder.
    static func flagsChangedTargets<Surface: AnyObject>(
      hovered: Surface?,
      modifierHolders: [Surface],
      isRelease: Bool,
      keyResponder: AnyObject?
    ) -> [Surface] {
      var targets: [Surface] = []
      if let hovered, hovered !== keyResponder {
        targets.append(hovered)
      }
      guard isRelease else { return targets }
      for holder in modifierHolders where holder !== keyResponder && holder !== hovered {
        targets.append(holder)
      }
      return targets
    }
  }
}

extension GhosttySurfaceView: NSTextInputClient {
  func hasMarkedText() -> Bool {
    markedText.length > 0
  }

  func markedRange() -> NSRange {
    guard markedText.length > 0 else { return NSRange() }
    return NSRange(location: 0, length: markedText.length)
  }

  func selectedRange() -> NSRange {
    guard let surface else { return NSRange() }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
    defer { ghostty_surface_free_text(surface, &text) }
    return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    switch string {
    case let attributedText as NSAttributedString:
      markedText = NSMutableAttributedString(attributedString: attributedText)
    case let stringValue as String:
      markedText = NSMutableAttributedString(string: stringValue)
    default:
      return
    }
    if keyTextAccumulator == nil {
      syncPreedit()
    }
  }

  func unmarkText() {
    if markedText.length > 0 {
      markedText.mutableString.setString("")
      syncPreedit()
    }
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    []
  }

  func attributedSubstring(
    forProposedRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSAttributedString? {
    guard let surface else { return nil }
    guard range.length > 0 else { return nil }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    var attributes: [NSAttributedString.Key: Any] = [:]
    if let fontRaw = ghostty_surface_quicklook_font(surface) {
      let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
      attributes[.font] = font.takeUnretainedValue()
      font.release()
    }
    return NSAttributedString(string: String(cString: text.text), attributes: attributes)
  }

  func characterIndex(for point: NSPoint) -> Int {
    0
  }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let surface else {
      return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
    }
    var caretX: Double = 0
    var caretY: Double = 0
    var width: Double = cellSize.width
    var height: Double = cellSize.height
    if range.length > 0, range != selectedRange() {
      var text = ghostty_text_s()
      if ghostty_surface_read_selection(surface, &text) {
        caretX = text.tl_px_x - 2
        caretY = text.tl_px_y + 2
        ghostty_surface_free_text(surface, &text)
      } else {
        ghostty_surface_ime_point(surface, &caretX, &caretY, &width, &height)
      }
    } else {
      ghostty_surface_ime_point(surface, &caretX, &caretY, &width, &height)
    }
    if range.length == 0, width > 0 {
      width = 0
      caretX += cellSize.width * Double(range.location + range.length)
    }
    let viewRect = NSRect(
      x: caretX,
      y: frame.size.height - caretY,
      width: width,
      height: max(height, cellSize.height)
    )
    let winRect = convert(viewRect, to: nil)
    guard let window else { return winRect }
    return window.convertToScreen(winRect)
  }

  func insertText(_ string: Any, replacementRange: NSRange) {
    guard NSApp.currentEvent != nil else { return }
    guard let surface else { return }
    var chars = ""
    switch string {
    case let attributedText as NSAttributedString:
      chars = attributedText.string
    case let stringValue as String:
      chars = stringValue
    default:
      return
    }
    unmarkText()
    if var acc = keyTextAccumulator {
      acc.append(chars)
      keyTextAccumulator = acc
      return
    }
    let len = chars.utf8CString.count
    if len == 0 { return }
    chars.withCString { ptr in
      ghostty_surface_text(surface, ptr, UInt(len - 1))
    }
  }
}

extension GhosttySurfaceView: NSServicesMenuRequestor {
  override func validRequestor(
    forSendType sendType: NSPasteboard.PasteboardType?,
    returnType: NSPasteboard.PasteboardType?
  ) -> Any? {
    let receivable: [NSPasteboard.PasteboardType] = [.string, .init("public.utf8-plain-text")]
    let sendable = receivable
    let sendableRequiresSelection = sendable

    if (returnType == nil || receivable.contains(returnType!))
      && (sendType == nil || sendable.contains(sendType!))
    {
      if let sendType, sendableRequiresSelection.contains(sendType) {
        if surface == nil || !ghostty_surface_has_selection(surface) {
          return super.validRequestor(forSendType: sendType, returnType: returnType)
        }
      }
      return self
    }
    return super.validRequestor(forSendType: sendType, returnType: returnType)
  }

  func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
    guard let surface else { return false }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return false }
    defer { ghostty_surface_free_text(surface, &text) }
    pboard.declareTypes([.string], owner: nil)
    pboard.setString(String(cString: text.text), forType: .string)
    return true
  }

  /// Sends raw text directly to the terminal PTY, bypassing the text input system.
  func sendText(_ text: String) {
    guard let surface else {
      surfaceLogger.warning("sendText: surface not available, dropping \(text.count) chars.")
      return
    }
    let len = text.utf8CString.count
    guard len > 0 else { return }
    text.withCString { ptr in
      ghostty_surface_text(surface, ptr, UInt(len - 1))
    }
  }

  func readSelection(from pboard: NSPasteboard) -> Bool {
    guard let str = pboard.getOpinionatedStringContents() else { return false }
    let len = str.utf8CString.count
    if len == 0 { return true }
    str.withCString { ptr in
      ghostty_surface_text(surface, ptr, UInt(len - 1))
    }
    return true
  }
}

final class GhosttySurfaceScrollView: NSView, WindowTintMaskRegion {
  private struct ScrollbarState {
    let total: UInt64
    let offset: UInt64
    let length: UInt64
  }

  private let scrollView: NSScrollView
  private let documentView: NSView
  private let surfaceView: GhosttySurfaceView
  private var observers: [NSObjectProtocol] = []
  private var isLiveScrolling = false
  private var lastSentRow: Int?
  private var scrollbar: ScrollbarState?

  init(surfaceView: GhosttySurfaceView) {
    self.surfaceView = surfaceView
    scrollView = NSScrollView()
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = false
    scrollView.usesPredominantAxisScrolling = true
    scrollView.scrollerStyle = .overlay
    scrollView.drawsBackground = false
    scrollView.contentView.clipsToBounds = false
    documentView = NSView(frame: .zero)
    scrollView.documentView = documentView
    documentView.addSubview(surfaceView)
    super.init(frame: .zero)
    addSubview(scrollView)
    surfaceView.scrollWrapper = self
    refreshAppearance()

    scrollView.contentView.postsBoundsChangedNotifications = true
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: scrollView.contentView,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.handleScrollChange()
        }
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSScrollView.willStartLiveScrollNotification,
        object: scrollView,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.isLiveScrolling = true
        }
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSScrollView.didEndLiveScrollNotification,
        object: scrollView,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.isLiveScrolling = false
        }
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSScrollView.didLiveScrollNotification,
        object: scrollView,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.handleLiveScroll()
        }
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSScroller.preferredScrollerStyleDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.handleScrollerStyleChange()
        }
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: .ghosttyRuntimeConfigDidChange,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.refreshAppearance()
        }
      })
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  nonisolated deinit {
    MainActor.assumeIsolated {
      observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
  }

  override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

  override func layout() {
    super.layout()
    scrollView.frame = bounds
    surfaceView.frame.size = scrollView.bounds.size
    documentView.frame.size.width = scrollView.bounds.width
    synchronizeScrollView()
    synchronizeSurfaceView()
    synchronizeCoreSurface()
    // This wrapper is the tint's subtract mask; the rebuild runs inline so
    // the hole lands in the same frame as the surface's geometry.
    NotificationCenter.default.post(name: .ghosttyTintMaskRegionDidChange, object: self)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.post(name: .ghosttyTintMaskRegionDidChange, object: self)
  }

  func updateSurfaceSize() {
    synchronizeCoreSurface()
    needsLayout = true
  }

  func updateScrollbar(total: UInt64, offset: UInt64, length: UInt64) {
    scrollbar = ScrollbarState(total: total, offset: offset, length: length)
    synchronizeScrollView()
  }

  func refreshAppearance() {
    scrollView.hasVerticalScroller = surfaceView.shouldShowScrollbar()
    scrollView.appearance = NSAppearance(named: surfaceView.scrollbarAppearanceName())
    scrollView.scrollerStyle = .overlay
    updateTrackingAreas()
  }

  private func handleScrollChange() {
    synchronizeSurfaceView()
  }

  private func handleScrollerStyleChange() {
    refreshAppearance()
    synchronizeCoreSurface()
  }

  private func synchronizeSurfaceView() {
    let visibleRect = scrollView.contentView.documentVisibleRect
    surfaceView.frame.origin = visibleRect.origin
  }

  private func synchronizeCoreSurface() {
    guard
      let contentSize = Self.reportedSurfaceSize(
        scrollContentSize: scrollView.contentSize,
        surfaceFrameSize: surfaceView.frame.size
      )
    else { return }
    surfaceView.updateSurfaceSize(contentSize: contentSize)
  }

  private func synchronizeScrollView() {
    documentView.frame.size.height = documentHeight()
    if !isLiveScrolling {
      let cellHeight = surfaceView.currentCellSize().height
      if cellHeight > 0, let scrollbar {
        let offsetY =
          CGFloat(scrollbar.total - scrollbar.offset - scrollbar.length) * cellHeight
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
        lastSentRow = Int(scrollbar.offset)
      }
    }
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  private func handleLiveScroll() {
    let cellHeight = surfaceView.currentCellSize().height
    guard cellHeight > 0 else { return }
    let visibleRect = scrollView.contentView.documentVisibleRect
    let documentHeight = documentView.frame.height
    let scrollOffset = documentHeight - visibleRect.origin.y - visibleRect.height
    let row = Int(scrollOffset / cellHeight)
    guard row != lastSentRow else { return }
    lastSentRow = row
    surfaceView.performBindingAction("scroll_to_row:\(row)")
  }

  private func documentHeight() -> CGFloat {
    let contentHeight = scrollView.contentSize.height
    let cellHeight = surfaceView.currentCellSize().height
    if cellHeight > 0, let scrollbar {
      let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
      let padding = contentHeight - (CGFloat(scrollbar.length) * cellHeight)
      return documentGridHeight + padding
    }
    return contentHeight
  }

  override func mouseMoved(with event: NSEvent) {
    guard NSScroller.preferredScrollerStyle == .legacy else { return }
    scrollView.flashScrollers()
  }

  override func updateTrackingAreas() {
    trackingAreas.forEach { removeTrackingArea($0) }
    super.updateTrackingAreas()
    guard let scroller = scrollView.verticalScroller else { return }
    addTrackingArea(
      NSTrackingArea(
        rect: convert(scroller.bounds, from: scroller),
        options: [
          .mouseMoved,
          .activeInKeyWindow,
        ],
        owner: self,
        userInfo: nil
      ))
  }

  static func reportedSurfaceSize(
    scrollContentSize: CGSize,
    surfaceFrameSize: CGSize
  ) -> CGSize? {
    let width = scrollContentSize.width
    let height = surfaceFrameSize.height
    guard width > 0, height > 0 else { return nil }
    return CGSize(width: width, height: height)
  }
}
