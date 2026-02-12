import AppKit
import Carbon
import CoreText
import GhosttyKit
import QuartzCore

final class GhosttySurfaceView: NSView, Identifiable {
  private struct ScrollbarState {
    let total: UInt64
    let offset: UInt64
    let length: UInt64
  }

  private let runtime: GhosttyRuntime
  let id = UUID()
  let bridge: GhosttySurfaceBridge
  private(set) var surface: ghostty_surface_t?
  private var surfaceRef: GhosttyRuntime.SurfaceReference?
  private let workingDirectoryCString: UnsafeMutablePointer<CChar>?
  private let initialInputCString: UnsafeMutablePointer<CChar>?
  private let fontSize: Float32
  private let context: ghostty_surface_context_e
  private var trackingArea: NSTrackingArea?
  private var lastBackingSize: CGSize = .zero
  private var lastPerformKeyEvent: TimeInterval?
  private var currentCursor: NSCursor = .iBeam
  private var focused = false
  private var markedText = NSMutableAttributedString()
  private var keyTextAccumulator: [String]?
  private var cellSize: CGSize = .zero
  private var lastScrollbar: ScrollbarState?
  private var eventMonitor: Any?
  private var notificationObservers: [NSObjectProtocol] = []
  private var prevPressureStage: Int = 0
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
  var onFocusChange: ((Bool) -> Void)?

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

  override var acceptsFirstResponder: Bool { true }

  init(
    runtime: GhosttyRuntime,
    workingDirectory: URL?,
    initialInput: String? = nil,
    fontSize: Float32? = nil,
    context: ghostty_surface_context_e
  ) {
    self.runtime = runtime
    self.bridge = GhosttySurfaceBridge()
    self.fontSize = fontSize ?? 0
    self.context = context
    if let workingDirectory {
      let path = workingDirectory.path(percentEncoded: false)
      workingDirectoryCString = path.withCString { strdup($0) }
    } else {
      workingDirectoryCString = nil
    }
    if let initialInput {
      initialInputCString = initialInput.withCString { strdup($0) }
    } else {
      initialInputCString = nil
    }
    super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    wantsLayer = true
    bridge.surfaceView = self
    createSurface()
    if let surface {
      surfaceRef = runtime.registerSurface(surface)
    }
    registerForDraggedTypes(Array(Self.dropTypes))

    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown]) {
      [weak self] event in
      self?.localEventHandler(event)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  deinit {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
    }
    clearNotificationObservers()
    let id = ObjectIdentifier(self)
    MainActor.assumeIsolated {
      SecureInput.shared.removeScoped(id)
    }
    closeSurface()
    if let workingDirectoryCString {
      free(workingDirectoryCString)
    }
    if let initialInputCString {
      free(initialInputCString)
    }
  }

  func closeSurface() {
    clearNotificationObservers()
    if let surface {
      if let surfaceRef {
        runtime.unregisterSurface(surfaceRef)
        self.surfaceRef = nil
      }
      ghostty_surface_free(surface)
      self.surface = nil
      bridge.surface = nil
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
        self?.windowDidChangeScreen()
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
    updateScreenObservers()
    updateContentScale()
    updateSurfaceSize()
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
    updateSurfaceSize()
  }

  override func layout() {
    super.layout()
    updateSurfaceSize()
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

  func focusDidChange(_ focused: Bool) {
    guard surface != nil else { return }
    guard self.focused != focused else { return }
    self.focused = focused
    if focused {
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
    // De facto role used by terminal emulators; AppKit doesn't provide a named constant for it.
    NSAccessibility.Role(rawValue: "AXTerminal")
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
    bridge.state.pwd
  }

  override func accessibilityHelp() -> String? {
    accessibilityPaneIndexHelp
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

  override func keyDown(with event: NSEvent) {
    guard let surface else {
      interpretKeyEvents([event])
      return
    }
    bridge.state.bellCount = 0
    let (translationEvent, translationMods) = translationState(event, surface: surface)
    let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
    keyTextAccumulator = []
    defer { keyTextAccumulator = nil }
    let markedTextBefore = markedText.length > 0
    let keyboardIdBefore = markedTextBefore ? nil : keyboardLayoutId()
    lastPerformKeyEvent = nil
    interpretKeyEvents([translationEvent])
    if !markedTextBefore, keyboardIdBefore != keyboardLayoutId() {
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
    sendKey(action: GHOSTTY_ACTION_RELEASE, event: event)
  }

  override func flagsChanged(with event: NSEvent) {
    let mod: UInt32
    switch event.keyCode {
    case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
    case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
    case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
    case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
    case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
    default: return
    }
    if hasMarkedText() { return }
    let mods = ghosttyMods(event.modifierFlags)
    var action = GHOSTTY_ACTION_RELEASE
    if (mods.rawValue & mod) != 0 {
      let sidePressed: Bool
      switch event.keyCode {
      case 0x3C:
        sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
      case 0x3E:
        sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
      case 0x3D:
        sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
      case 0x36:
        sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
      default:
        sidePressed = true
      }
      if sidePressed {
        action = GHOSTTY_ACTION_PRESS
      }
    }
    sendKey(action: action, event: event)
  }

  override func mouseMoved(with event: NSEvent) {
    sendMousePosition(event)
    if let window, window.isKeyWindow, !focused, runtime.focusFollowsMouse() {
      requestFocus()
    }
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    sendMousePosition(event)
  }

  override func mouseExited(with event: NSEvent) {
    if NSEvent.pressedMouseButtons != 0 {
      return
    }
    guard let surface else { return }
    let mods = ghosttyMods(event.modifierFlags)
    ghostty_surface_mouse_pos(surface, -1, -1, mods)
  }

  override func mouseDown(with event: NSEvent) {
    sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
  }

  override func mouseUp(with event: NSEvent) {
    prevPressureStage = 0
    sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    if let surface {
      ghostty_surface_mouse_pressure(surface, 0, 0)
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    guard let surface else {
      super.rightMouseDown(with: event)
      return
    }
    let mods = ghosttyMods(event.modifierFlags)
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
    let mods = ghosttyMods(event.modifierFlags)
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

  private func localEventHandler(_ event: NSEvent) -> NSEvent? {
    switch event.type {
    case .keyUp:
      localEventKeyUp(event)
    case .leftMouseDown:
      localEventLeftMouseDown(event)
    default:
      event
    }
  }

  private func localEventKeyUp(_ event: NSEvent) -> NSEvent? {
    if !event.modifierFlags.contains(.command) { return event }
    guard focused else { return event }
    keyUp(with: event)
    return nil
  }

  private func localEventLeftMouseDown(_ event: NSEvent) -> NSEvent? {
    guard let window, event.window != nil, window == event.window else { return event }
    let location = convert(event.locationInWindow, from: nil)
    guard hitTest(location) == self else { return event }
    guard !NSApp.isActive || !window.isKeyWindow else { return event }
    guard !focused else { return event }
    window.makeFirstResponder(self)
    return event
  }

  func updateSurfaceSize() {
    guard let surface else { return }
    let backingSize = convertToBacking(bounds.size)
    if backingSize == lastBackingSize {
      return
    }
    lastBackingSize = backingSize
    let width = UInt32(max(1, Int(backingSize.width.rounded(.down))))
    let height = UInt32(max(1, Int(backingSize.height.rounded(.down))))
    let currentSize = ghostty_surface_size(surface)
    guard currentSize.cell_width_px > 0, currentSize.cell_height_px > 0 else {
      ghostty_surface_set_size(surface, width, height)
      return
    }
    let columns = Int(width) / Int(currentSize.cell_width_px)
    let rows = Int(height) / Int(currentSize.cell_height_px)
    guard columns >= 5, rows >= 2 else { return }
    ghostty_surface_set_size(surface, width, height)
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
    config.initial_input = initialInputCString.map { UnsafePointer($0) }
    config.context = context
    surface = ghostty_surface_new(app, &config)
    bridge.surface = surface
    updateSurfaceSize()
  }

  private func updateContentScale() {
    guard let surface else { return }
    let scale = backingScaleFactor()
    ghostty_surface_set_content_scale(surface, scale, scale)
  }

  private func backingScaleFactor() -> Double {
    if let window {
      return window.backingScaleFactor
    }
    if let screen = NSScreen.main {
      return screen.backingScaleFactor
    }
    return 2.0
  }

  func setOcclusion(_ visible: Bool) {
    guard let surface else { return }
    ghostty_surface_set_occlusion(surface, visible)
  }

  private func setSurfaceFocus(_ focused: Bool) {
    guard let surface else { return }
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
        try? await Task.sleep(for: .seconds(delay))
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
    guard focused else { return false }

    if let bindingFlags = bindingFlags(for: event, surface: surface) {
      if shouldAttemptMenu(for: bindingFlags),
        let menu = NSApp.mainMenu,
        menu.performKeyEquivalent(with: event)
      {
        return true
      }
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
      let mods = ghosttyMods(event.modifierFlags)
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
    guard let surface else { return }
    _ = action.withCString { ptr in
      ghostty_surface_binding_action(surface, ptr, UInt(action.lengthOfBytes(using: .utf8)))
    }
  }

  private func translationState(_ event: NSEvent, surface: ghostty_surface_t) -> (
    NSEvent, NSEvent.ModifierFlags
  ) {
    let translatedModsGhostty = ghostty_surface_key_translation_mods(
      surface, ghosttyMods(event.modifierFlags))
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
    keyEvent.mods = ghosttyMods(originalMods)
    keyEvent.consumed_mods = ghosttyMods(translationMods.subtracting([.control, .command]))
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

  private func ghosttyCharacters(_ event: NSEvent) -> String? {
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
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
      return nil
    }
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
      return nil
    }
    let value = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
    return value as String
  }

  private func sendMousePosition(_ event: NSEvent) {
    guard let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    let yPosition = bounds.height - point.y
    let mods = ghosttyMods(event.modifierFlags)
    ghostty_surface_mouse_pos(surface, point.x, yPosition, mods)
  }

  private func sendMouseButton(
    _ event: NSEvent,
    state: ghostty_input_mouse_state_e,
    button: ghostty_input_mouse_button_e
  ) {
    guard let surface else { return }
    let mods = ghosttyMods(event.modifierFlags)
    ghostty_surface_mouse_button(surface, state, button, mods)
  }

  private func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
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

final class GhosttySurfaceScrollView: NSView {
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
        self?.handleScrollChange()
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSScrollView.willStartLiveScrollNotification,
        object: scrollView,
        queue: .main
      ) { [weak self] _ in
        self?.isLiveScrolling = true
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSScrollView.didEndLiveScrollNotification,
        object: scrollView,
        queue: .main
      ) { [weak self] _ in
        self?.isLiveScrolling = false
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSScrollView.didLiveScrollNotification,
        object: scrollView,
        queue: .main
      ) { [weak self] _ in
        self?.handleLiveScroll()
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSScroller.preferredScrollerStyleDidChangeNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        self?.handleScrollerStyleChange()
      })

    observers.append(
      NotificationCenter.default.addObserver(
        forName: .ghosttyRuntimeConfigDidChange,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.refreshAppearance()
      })
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  override func layout() {
    super.layout()
    scrollView.frame = bounds
    surfaceView.frame.size = scrollView.bounds.size
    documentView.frame.size.width = scrollView.bounds.width
    synchronizeScrollView()
    synchronizeSurfaceView()
    surfaceView.updateSurfaceSize()
  }

  func updateSurfaceSize() {
    surfaceView.updateSurfaceSize()
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
    surfaceView.updateSurfaceSize()
  }

  private func synchronizeSurfaceView() {
    let visibleRect = scrollView.contentView.documentVisibleRect
    surfaceView.frame.origin = visibleRect.origin
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
}
