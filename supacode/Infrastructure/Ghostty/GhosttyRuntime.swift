import AppKit
import GhosttyKit
import Sharing
import SupacodeSettingsShared
import SwiftUI
import UniformTypeIdentifiers

final class GhosttyRuntime {
  private static let logger = SupaLogger("Ghostty")

  final class SurfaceReference {
    let surface: ghostty_surface_t
    var isValid = true

    init(_ surface: ghostty_surface_t) {
      self.surface = surface
    }

    func invalidate() {
      isValid = false
    }
  }

  private var config: ghostty_config_t?
  private(set) var app: ghostty_app_t?
  private var observers: [NSObjectProtocol] = []
  private var surfaceRefs: [SurfaceReference] = []
  private var lastColorScheme: ghostty_color_scheme_e?
  /// Whether the user has toggled background opacity to force
  /// an opaque window, overriding the configured transparency.
  private(set) var isBackgroundOpaque = false

  func toggleIsBackgroundOpaque() {
    isBackgroundOpaque.toggle()
  }
  var onConfigChange: (() -> Void)?

  init() {
    guard let config = Self.loadConfig() else {
      preconditionFailure("ghostty_config_new failed")
    }
    self.config = config

    var runtimeConfig = ghostty_runtime_config_s(
      userdata: Unmanaged.passUnretained(self).toOpaque(),
      supports_selection_clipboard: true,
      wakeup_cb: { @Sendable userdata in
        GhosttyRuntime.wakeupCallback(userdata)
      },
      action_cb: { @Sendable app, target, action in
        GhosttyRuntime.actionCallback(app, target, action)
      },
      read_clipboard_cb: { @Sendable userdata, location, state in
        GhosttyRuntime.readClipboardCallback(userdata, location, state)
      },
      confirm_read_clipboard_cb: { @Sendable userdata, string, state, request in
        GhosttyRuntime.confirmReadClipboardCallback(userdata, string, state, request)
      },
      write_clipboard_cb: { @Sendable userdata, location, content, len, confirm in
        GhosttyRuntime.writeClipboardCallback(userdata, location, content, len, confirm)
      },
      close_surface_cb: { @Sendable userdata, processAlive in
        GhosttyRuntime.closeSurfaceCallback(userdata, processAlive)
      }
    )

    guard let app = ghostty_app_new(&runtimeConfig, config) else {
      preconditionFailure("ghostty_app_new failed")
    }
    self.app = app

    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.setAppFocus(true)
        }
      })
    observers.append(
      center.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.setAppFocus(false)
        }
      })
    observers.append(
      center.addObserver(
        forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let app = self?.app else { return }
          ghostty_app_keyboard_changed(app)
        }
      })
  }

  isolated deinit {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
    }
    if let app {
      ghostty_app_free(app)
    }
    if let config {
      ghostty_config_free(config)
    }
  }

  func setAppFocus(_ focused: Bool) {
    if let app {
      ghostty_app_set_focus(app, focused)
    }
  }

  func tick() {
    if let app {
      ghostty_app_tick(app)
    }
  }

  func setColorScheme(_ scheme: ColorScheme) {
    guard let app else { return }
    let ghosttyScheme: ghostty_color_scheme_e =
      scheme == .dark
      ? GHOSTTY_COLOR_SCHEME_DARK
      : GHOSTTY_COLOR_SCHEME_LIGHT
    lastColorScheme = ghosttyScheme
    ghostty_app_set_color_scheme(app, ghosttyScheme)
    applyColorSchemeToSurfaces(ghosttyScheme)
  }

  func registerSurface(_ surface: ghostty_surface_t) -> SurfaceReference {
    let ref = SurfaceReference(surface)
    surfaceRefs.append(ref)
    surfaceRefs = surfaceRefs.filter { $0.isValid }
    if let lastColorScheme {
      ghostty_surface_set_color_scheme(surface, lastColorScheme)
    }
    return ref
  }

  func unregisterSurface(_ ref: SurfaceReference) {
    ref.invalidate()
    surfaceRefs = surfaceRefs.filter { $0.isValid }
  }

  /// Reloads the full app config from disk and re-applies the current color scheme.
  func reloadAppConfig() {
    guard let app else {
      Self.logger.warning("Cannot reload app config: Ghostty app instance is nil.")
      return
    }
    isBackgroundOpaque = false
    var target = ghostty_target_s()
    target.tag = GHOSTTY_TARGET_APP
    guard let config = Self.loadConfig() else {
      Self.logger.warning("Failed to reload app config.")
      return
    }
    applyConfig(config, target: target, app: app)
    ghostty_config_free(config)
    if let lastColorScheme {
      ghostty_app_set_color_scheme(app, lastColorScheme)
      applyColorSchemeToSurfaces(lastColorScheme)
    }
  }

  func reloadConfig(soft: Bool, target: ghostty_target_s) {
    guard let app else { return }
    if soft, let config {
      guard let clone = ghostty_config_clone(config) else { return }
      applyConfig(clone, target: target, app: app)
      ghostty_config_free(clone)
      return
    }
    guard let config = Self.loadConfig() else { return }
    applyConfig(config, target: target, app: app)
    ghostty_config_free(config)
  }

  private func applyConfig(
    _ config: ghostty_config_t,
    target: ghostty_target_s,
    app: ghostty_app_t
  ) {
    switch target.tag {
    case GHOSTTY_TARGET_APP:
      ghostty_app_update_config(app, config)
    case GHOSTTY_TARGET_SURFACE:
      guard let surface = target.target.surface else { return }
      ghostty_surface_update_config(surface, config)
    default:
      return
    }
  }

  private func applyColorSchemeToSurfaces(_ scheme: ghostty_color_scheme_e) {
    for ref in surfaceRefs where ref.isValid {
      ghostty_surface_set_color_scheme(ref.surface, scheme)
    }
  }

  private static func runtime(from userdata: UnsafeMutableRawPointer?) -> GhosttyRuntime? {
    guard let userdata else { return nil }
    return Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
  }

  private static func runtime(fromApp app: ghostty_app_t) -> GhosttyRuntime? {
    guard let userdata = ghostty_app_userdata(app) else { return nil }
    return runtime(from: userdata)
  }

  private static func surfaceBridge(fromUserdata userdata: UnsafeMutableRawPointer?)
    -> GhosttySurfaceBridge?
  {
    guard let userdata else { return nil }
    return Unmanaged<GhosttySurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
  }

  private static func surfaceBridge(fromSurface surface: ghostty_surface_t?)
    -> GhosttySurfaceBridge?
  {
    guard let surface, let userdata = ghostty_surface_userdata(surface) else { return nil }
    return Unmanaged<GhosttySurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
  }

  private nonisolated static func wakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    let userdataBits = userdata.map { UInt(bitPattern: $0) }
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        wakeup(userdataBits: userdataBits)
      }
      return
    }
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        wakeup(userdataBits: userdataBits)
      }
    }
  }

  private nonisolated static func actionCallback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
  ) -> Bool {
    guard let app else { return false }
    let appBits = UInt(bitPattern: app)
    if Thread.isMainThread {
      return MainActor.assumeIsolated {
        handleAction(appBits: appBits, target: target, action: action)
      }
    }
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        _ = handleAction(appBits: appBits, target: target, action: action)
      }
    }
    return false
  }

  private nonisolated static func readClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
  ) -> Bool {
    let userdataBits = userdata.map { UInt(bitPattern: $0) }
    let stateBits = state.map { UInt(bitPattern: $0) }
    if Thread.isMainThread {
      return MainActor.assumeIsolated {
        readClipboard(userdataBits: userdataBits, location: location, stateBits: stateBits)
      }
    }
    return DispatchQueue.main.sync {
      MainActor.assumeIsolated {
        readClipboard(userdataBits: userdataBits, location: location, stateBits: stateBits)
      }
    }
  }

  private nonisolated static func confirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
  ) {
    guard let string else { return }
    let value = String(cString: string)
    let userdataBits = userdata.map { UInt(bitPattern: $0) }
    let stateBits = state.map { UInt(bitPattern: $0) }
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        confirmReadClipboard(
          userdataBits: userdataBits,
          value: value,
          stateBits: stateBits,
          request: request
        )
      }
      return
    }
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        confirmReadClipboard(
          userdataBits: userdataBits,
          value: value,
          stateBits: stateBits,
          request: request
        )
      }
    }
  }

  private nonisolated static func writeClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ len: Int,
    _ confirm: Bool
  ) {
    _ = userdata
    guard let content, len > 0 else { return }
    let items: [(mime: String, data: String)] = (0..<len).compactMap { index in
      let item = content.advanced(by: index).pointee
      guard let mimePtr = item.mime, let dataPtr = item.data else { return nil }
      return (mime: String(cString: mimePtr), data: String(cString: dataPtr))
    }
    guard !items.isEmpty else { return }
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        writeClipboard(
          location: location,
          items: items,
          confirm: confirm
        )
      }
      return
    }
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        writeClipboard(
          location: location,
          items: items,
          confirm: confirm
        )
      }
    }
  }

  private nonisolated static func closeSurfaceCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
  ) {
    let userdataBits = userdata.map { UInt(bitPattern: $0) }
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        closeSurface(userdataBits: userdataBits, processAlive: processAlive)
      }
      return
    }
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        closeSurface(userdataBits: userdataBits, processAlive: processAlive)
      }
    }
  }

  private static func wakeup(userdataBits: UInt?) {
    let userdata = userdataBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    guard let runtime = runtime(from: userdata) else { return }
    runtime.tick()
  }

  private static func handleAction(
    appBits: UInt,
    target: ghostty_target_s,
    action: ghostty_action_s
  ) -> Bool {
    guard let app = ghostty_app_t(bitPattern: appBits) else { return false }
    if let runtime = runtime(fromApp: app) {
      if action.tag == GHOSTTY_ACTION_CONFIG_CHANGE, target.tag == GHOSTTY_TARGET_APP {
        let config = action.action.config_change.config
        guard let clone = ghostty_config_clone(config) else { return false }
        runtime.setConfig(clone)
        runtime.onConfigChange?()
        NotificationCenter.default.post(name: .ghosttyRuntimeConfigDidChange, object: runtime)
      }
      if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG {
        let soft = action.action.reload_config.soft
        runtime.reloadConfig(soft: soft, target: target)
      }
    }
    guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
    guard let surface = target.target.surface else { return false }
    guard let bridge = surfaceBridge(fromSurface: surface) else { return false }
    return bridge.handleAction(target: target, action: action)
  }

  private static func readClipboard(
    userdataBits: UInt?,
    location: ghostty_clipboard_e,
    stateBits: UInt?
  ) -> Bool {
    let userdata = userdataBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    let state = stateBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    guard let bridge = surfaceBridge(fromUserdata: userdata), let surface = bridge.surface else {
      return false
    }
    guard let value = NSPasteboard.ghostty(location)?.getOpinionatedStringContents() else {
      return false
    }
    value.withCString { ptr in
      ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
    }
    return true
  }

  private static func confirmReadClipboard(
    userdataBits: UInt?,
    value: String,
    stateBits: UInt?,
    request: ghostty_clipboard_request_e
  ) {
    _ = request
    let userdata = userdataBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    let state = stateBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    guard let bridge = surfaceBridge(fromUserdata: userdata), let surface = bridge.surface else {
      return
    }
    value.withCString { ptr in
      ghostty_surface_complete_clipboard_request(surface, ptr, state, true)
    }
  }

  private static func writeClipboard(
    location: ghostty_clipboard_e,
    items: [(mime: String, data: String)],
    confirm: Bool
  ) {
    _ = confirm

    guard let pasteboard = NSPasteboard.ghostty(location) else { return }
    let types = items.compactMap { NSPasteboard.PasteboardType(mimeType: $0.mime) }
    pasteboard.declareTypes(types, owner: nil)
    for item in items {
      guard let type = NSPasteboard.PasteboardType(mimeType: item.mime) else { continue }
      pasteboard.setString(item.data, forType: type)
    }
  }

  private static func closeSurface(userdataBits: UInt?, processAlive: Bool) {
    let userdata = userdataBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    guard let bridge = surfaceBridge(fromUserdata: userdata) else { return }
    bridge.closeSurface(processAlive: processAlive)
  }

  private func setConfig(_ config: ghostty_config_t) {
    if let existing = self.config {
      ghostty_config_free(existing)
    }
    self.config = config
  }

  private static func loadConfig() -> ghostty_config_t? {
    @Shared(.settingsFile) var settingsFile
    guard let config = ghostty_config_new() else { return nil }
    ghostty_config_load_default_files(config)
    ghostty_config_load_recursive_files(config)
    ghostty_config_load_cli_args(config)
    loadBundledOverrides(into: config)
    loadBundledTheme(into: config, enabled: settingsFile.global.terminalThemeSyncEnabled)
    ghostty_config_finalize(config)
    return config
  }

  /// Applies Supacode-specific config (padding values) that takes precedence over user settings.
  private static func loadBundledOverrides(into config: ghostty_config_t) {
    let defaults = "window-padding-x = 14\nwindow-padding-y = 12,0\n"
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("supacode-defaults.conf")
    do {
      try defaults.write(to: tempURL, atomically: true, encoding: .utf8)
    } catch {
      logger.warning("Failed to write bundled defaults: \(error.localizedDescription)")
      return
    }
    tempURL.path.withCString { ghostty_config_load_file(config, $0) }
  }

  /// When terminal theme sync is enabled, loads the bundled Supacode
  /// light/dark theme, overriding any user-configured theme. When disabled, the user's Ghostty theme is preserved.
  private static func loadBundledTheme(into config: ghostty_config_t, enabled: Bool) {
    guard enabled else { return }
    guard
      let lightPath = Bundle.main.path(forResource: "Supacode Light", ofType: nil),
      let darkPath = Bundle.main.path(forResource: "Supacode Dark", ofType: nil)
    else {
      assertionFailure("Bundled Supacode themes missing from app bundle.")
      logger.warning("Bundled Supacode themes missing from app bundle.")
      return
    }
    let line = "theme = light:\(lightPath),dark:\(darkPath)\n"
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("supacode-theme.conf")
    do {
      try line.write(to: tempURL, atomically: true, encoding: .utf8)
    } catch {
      logger.warning("Failed to write bundled theme config: \(error.localizedDescription)")
      return
    }
    tempURL.path.withCString { ghostty_config_load_file(config, $0) }
  }

  func keyboardShortcut(for action: String) -> KeyboardShortcut? {
    guard let config else { return nil }
    let trigger = ghostty_config_trigger(config, action, UInt(action.lengthOfBytes(using: .utf8)))
    return Self.keyboardShortcut(for: trigger)
  }

  func commandPaletteEntries() -> [GhosttyCommand] {
    guard let config else { return [] }
    var value = ghostty_config_command_list_s()
    let key = "command-palette-entry"
    guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))) else {
      return []
    }
    guard value.len > 0, let commands = value.commands else { return [] }
    let buffer = UnsafeBufferPointer(start: commands, count: Int(value.len))
    return buffer.map(GhosttyCommand.init(cValue:))
  }

  func focusFollowsMouse() -> Bool {
    guard let config else { return false }
    var value = false
    let key = "focus-follows-mouse"
    _ = ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8)))
    return value
  }

  func shouldShowScrollbar() -> Bool {
    guard let config else { return true }
    var valuePtr: UnsafePointer<CChar>?
    let key = "scrollbar"
    if ghostty_config_get(config, &valuePtr, key, UInt(key.lengthOfBytes(using: .utf8))),
      let ptr = valuePtr
    {
      return String(cString: ptr) != "never"
    }
    return true
  }

  func splitPreserveZoomOnNavigation() -> Bool {
    guard let config else { return false }
    var value: CUnsignedInt = 0
    let key = "split-preserve-zoom"
    guard ghostty_config_get(config, &value, key, UInt(key.count)) else { return false }
    // Ghostty's C API bitcasts packed structs into c_uint; the first field maps to bit 0.
    // https://github.com/ghostty-org/ghostty/blob/6057f8d/src/config/c_get.zig#L74-L84
    // https://github.com/ghostty-org/ghostty/blob/6057f8d/src/config/c_get.zig#L226-L240
    return value & (1 << 0) != 0
  }

  func backgroundOpacity() -> Double {
    guard let config else { return 1 }
    var value: Double = 1
    let key = "background-opacity"
    _ = ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8)))
    return min(max(value, 0.001), 1)
  }

  func backgroundColor() -> NSColor {
    backgroundColorFromConfig() ?? NSColor.windowBackgroundColor
  }

  func scrollbarAppearanceName() -> NSAppearance.Name {
    backgroundColor().isLightColor ? .aqua : .darkAqua
  }

  private func backgroundColorFromConfig() -> NSColor? {
    guard let config else { return nil }
    var color: ghostty_config_color_s = .init()
    let key = "background"
    if !ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) {
      return nil
    }
    return NSColor(ghostty: color)
  }

  private static func keyboardShortcut(for trigger: ghostty_input_trigger_s) -> KeyboardShortcut? {
    let key: KeyEquivalent
    switch trigger.tag {
    case GHOSTTY_TRIGGER_PHYSICAL:
      guard let equiv = keyToEquivalent[trigger.key.physical] else { return nil }
      key = equiv
    case GHOSTTY_TRIGGER_UNICODE:
      guard let scalar = UnicodeScalar(trigger.key.unicode) else { return nil }
      key = KeyEquivalent(Character(scalar))
    case GHOSTTY_TRIGGER_CATCH_ALL:
      return nil
    default:
      return nil
    }
    return KeyboardShortcut(key, modifiers: eventModifiers(mods: trigger.mods))
  }

  private static func eventModifiers(mods: ghostty_input_mods_e) -> EventModifiers {
    var flags: EventModifiers = []
    if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
    if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
    if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
    if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
    return flags
  }

  private static let keyToEquivalent: [ghostty_input_key_e: KeyEquivalent] = [
    GHOSTTY_KEY_ARROW_UP: .upArrow,
    GHOSTTY_KEY_ARROW_DOWN: .downArrow,
    GHOSTTY_KEY_ARROW_LEFT: .leftArrow,
    GHOSTTY_KEY_ARROW_RIGHT: .rightArrow,
    GHOSTTY_KEY_HOME: .home,
    GHOSTTY_KEY_END: .end,
    GHOSTTY_KEY_DELETE: .delete,
    GHOSTTY_KEY_PAGE_UP: .pageUp,
    GHOSTTY_KEY_PAGE_DOWN: .pageDown,
    GHOSTTY_KEY_ESCAPE: .escape,
    GHOSTTY_KEY_ENTER: .return,
    GHOSTTY_KEY_TAB: .tab,
    GHOSTTY_KEY_BACKSPACE: .delete,
    GHOSTTY_KEY_SPACE: .space,
  ]
}

extension Notification.Name {
  static let ghosttyRuntimeConfigDidChange = Notification.Name("ghosttyRuntimeConfigDidChange")
}

extension NSColor {
  fileprivate var isLightColor: Bool {
    luminance > 0.5
  }

  fileprivate var luminance: Double {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard let rgb = usingColorSpace(.sRGB) else { return 0 }
    rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return (0.299 * red) + (0.587 * green) + (0.114 * blue)
  }

  fileprivate convenience init(ghostty: ghostty_config_color_s) {
    let red = Double(ghostty.r) / 255
    let green = Double(ghostty.g) / 255
    let blue = Double(ghostty.b) / 255
    self.init(red: red, green: green, blue: blue, alpha: 1)
  }
}

extension NSPasteboard.PasteboardType {
  init?(mimeType: String) {
    switch mimeType {
    case "text/plain":
      self = .string
      return
    default:
      break
    }
    guard let utType = UTType(mimeType: mimeType) else {
      self.init(mimeType)
      return
    }
    self.init(utType.identifier)
  }
}

extension NSPasteboard {
  private static let ghosttyEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

  static func ghosttyEscape(_ str: String) -> String {
    var result = str
    for char in ghosttyEscapeCharacters {
      result = result.replacing(String(char), with: "\\\(char)")
    }
    return result
  }

  static var ghosttySelection: NSPasteboard = {
    NSPasteboard(name: .init("com.mitchellh.ghostty.selection"))
  }()

  func getOpinionatedStringContents() -> String? {
    if let urls = readObjects(forClasses: [NSURL.self]) as? [URL],
      urls.count > 0
    {
      return
        urls
        .map { $0.isFileURL ? Self.ghosttyEscape($0.path) : $0.absoluteString }
        .joined(separator: " ")
    }
    return string(forType: .string)
  }

  static func ghostty(_ clipboard: ghostty_clipboard_e) -> NSPasteboard? {
    switch clipboard {
    case GHOSTTY_CLIPBOARD_STANDARD:
      return Self.general
    case GHOSTTY_CLIPBOARD_SELECTION:
      return Self.ghosttySelection
    default:
      return nil
    }
  }
}
