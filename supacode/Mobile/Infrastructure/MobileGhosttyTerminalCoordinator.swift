import Foundation
import GhosttyKit
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
protocol MobileGhosttySurfaceActionHandling: AnyObject {
  var ghosttySurface: ghostty_surface_t? { get }
  func handleRuntimeAction(_ action: ghostty_action_s) -> Bool
}

@MainActor
@Observable
final class MobileTerminalSessionManager {
  private(set) var sessions: [MobileTerminalSession] = []
  private let runtime = MobileGhosttyRuntime()
  private var eventContinuation: AsyncStream<MobileTerminalClient.Event>.Continuation?
  private var pendingEvents: [MobileTerminalClient.Event] = []

  func handleCommand(_ command: MobileTerminalClient.Command) {
    switch command {
    case .openSession(let server, let commandOverride):
      guard let session = openSession(server: server, commandOverride: commandOverride) else { return }
      emit(.sessionOpened(id: session.id, serverID: server.id, title: session.terminalTitle))
    case .closeSession(let id):
      guard let session = sessions.first(where: { $0.id == id }) else { return }
      closeSession(session)
    case .setSelectedServerID:
      break
    case .setAppFocus(let focused):
      setAppFocus(focused)
    }
  }

  func eventStream() -> AsyncStream<MobileTerminalClient.Event> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(of: MobileTerminalClient.Event.self)
    eventContinuation = continuation
    if !pendingEvents.isEmpty {
      let buffered = pendingEvents
      pendingEvents.removeAll()
      for event in buffered {
        continuation.yield(event)
      }
    }
    return stream
  }

  func sessions(for serverID: MobileServer.ID) -> [MobileTerminalSession] {
    sessions.filter { $0.server.id == serverID }
  }

  func session(for id: UUID) -> MobileTerminalSession? {
    sessions.first { $0.id == id }
  }

  private func openSession(
    server: MobileServer,
    commandOverride: String?,
  ) -> MobileTerminalSession? {
    guard let command = server.terminalCommand(overrideCommand: commandOverride) else {
      return nil
    }

    let session = MobileTerminalSession(runtime: runtime, server: server, shellCommand: command)
    session.onTitleChange = { [weak self] id, title in
      self?.emit(.sessionTitleChanged(id: id, title: title))
    }
    session.onProcessExited = { [weak self] id in
      self?.emit(.sessionProcessExited(id: id))
    }
    sessions.append(session)
    return session
  }

  private func closeSession(_ session: MobileTerminalSession) {
    session.close()
    sessions.removeAll { $0.id == session.id }
    emit(.sessionClosed(id: session.id))
  }

  private func setAppFocus(_ focused: Bool) {
    runtime.setAppFocus(focused)
  }

  private func emit(_ event: MobileTerminalClient.Event) {
    guard let eventContinuation else {
      pendingEvents.append(event)
      return
    }
    eventContinuation.yield(event)
  }
}

@MainActor
@Observable
final class MobileTerminalSession: Identifiable {
  let id = UUID()
  let server: MobileServer
  let shellCommand: String
  let createdAt: Date
  let surfaceView: MobileGhosttySurfaceView
  var terminalTitle: String
  var isClosed = false

  var onTitleChange: ((UUID, String) -> Void)?
  var onProcessExited: ((UUID) -> Void)?

  init(runtime: MobileGhosttyRuntime, server: MobileServer, shellCommand: String) {
    self.server = server
    self.shellCommand = shellCommand
    createdAt = Date()
    terminalTitle = server.displayName

    surfaceView = MobileGhosttySurfaceView(runtime: runtime, shellCommand: shellCommand)
    surfaceView.onTitleChange = { [weak self] value in
      guard let self else { return }
      self.terminalTitle = value
      self.onTitleChange?(self.id, value)
    }
    surfaceView.onCloseRequest = { [weak self] _ in
      guard let self else { return }
      self.isClosed = true
      self.onProcessExited?(self.id)
    }
  }

  func close() {
    isClosed = true
    surfaceView.requestClose()
  }
}

@MainActor
final class MobileGhosttyRuntime {
  private var config: ghostty_config_t?
  private(set) var app: ghostty_app_t?
  private weak var clipboardSurface: (any MobileGhosttySurfaceActionHandling)?

  init() {
    guard let config = Self.loadConfig() else {
      preconditionFailure("ghostty_config_new failed")
    }
    self.config = config

    var runtimeConfig = ghostty_runtime_config_s(
      userdata: Unmanaged.passUnretained(self).toOpaque(),
      supports_selection_clipboard: true,
      wakeup_cb: { @Sendable userdata in
        MobileGhosttyRuntime.wakeupCallback(userdata: userdata)
      },
      action_cb: { @Sendable app, target, action in
        MobileGhosttyRuntime.actionCallback(app: app, target: target, action: action)
      },
      read_clipboard_cb: { @Sendable userdata, location, state in
        MobileGhosttyRuntime.readClipboardCallback(
          userdata: userdata,
          location: location,
          state: state,
        )
      },
      confirm_read_clipboard_cb: { @Sendable userdata, string, state, request in
        MobileGhosttyRuntime.confirmReadClipboardCallback(
          userdata: userdata,
          string: string,
          state: state,
          request: request,
        )
      },
      write_clipboard_cb: { @Sendable userdata, location, content, len, confirm in
        MobileGhosttyRuntime.writeClipboardCallback(
          userdata: userdata,
          location: location,
          content: content,
          len: len,
          confirm: confirm,
        )
      },
      close_surface_cb: { @Sendable userdata, processAlive in
        MobileGhosttyRuntime.closeSurfaceCallback(
          userdata: userdata,
          processAlive: processAlive,
        )
      },
    )

    guard let app = ghostty_app_new(&runtimeConfig, config) else {
      preconditionFailure("ghostty_app_new failed")
    }
    self.app = app
  }

  deinit {
    MainActor.assumeIsolated {
      if let app {
        ghostty_app_free(app)
      }
      if let config {
        ghostty_config_free(config)
      }
    }
  }

  func tick() {
    if let app {
      ghostty_app_tick(app)
    }
  }

  func registerClipboardSurface(_ surface: MobileGhosttySurfaceActionHandling) {
    clipboardSurface = surface
  }

  func unregisterClipboardSurface(_ surface: MobileGhosttySurfaceActionHandling) {
    if clipboardSurface == nil {
      return
    }
    if let current = clipboardSurface,
      current.ghosttySurface == surface.ghosttySurface
    {
      clipboardSurface = nil
    }
  }

  func setAppFocus(_ focused: Bool) {
    if let app {
      ghostty_app_set_focus(app, focused)
    }
  }

  private nonisolated static func runtime(from userdata: UnsafeMutableRawPointer?) -> MobileGhosttyRuntime? {
    guard let userdata else { return nil }
    return Unmanaged<MobileGhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
  }

  private nonisolated static func runtime(fromApp app: ghostty_app_t?) -> MobileGhosttyRuntime? {
    guard let userdata = ghostty_app_userdata(app) else { return nil }
    return runtime(from: userdata)
  }

  private nonisolated static func wakeupCallback(userdata: UnsafeMutableRawPointer?) {
    guard let runtime = runtime(from: userdata) else { return }
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        runtime.tick()
      }
      return
    }
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        runtime.tick()
      }
    }
  }

  private nonisolated static func actionCallback(
    app: ghostty_app_t?,
    target: ghostty_target_s,
    action: ghostty_action_s,
  ) -> Bool {
    guard let runtime = runtime(fromApp: app) else { return false }
    if target.tag == GHOSTTY_TARGET_SURFACE,
      let surface = target.target.surface,
      let userdata = ghostty_surface_userdata(surface)
    {
      let handler = Unmanaged<AnyObject>.fromOpaque(userdata).takeUnretainedValue()
      if let surfaceHandler = handler as? MobileGhosttySurfaceActionHandling {
        return MainActor.assumeIsolated {
          surfaceHandler.handleRuntimeAction(action)
        }
      }
      return false
    }

    _ = runtime
    return false
  }

  private nonisolated static func readClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    state: UnsafeMutableRawPointer?,
  ) {
    guard let stateBits = state.map({ UInt(bitPattern: $0) }) else { return }
    guard let runtime = runtime(from: userdata) else { return }

    if location == GHOSTTY_CLIPBOARD_SELECTION {
      return
    }

    let value = UIPasteboard.general.string ?? ""
    MainActor.assumeIsolated {
      guard let state = UnsafeMutableRawPointer(bitPattern: stateBits) else { return }
      guard let surface = runtime.clipboardSurface?.ghosttySurface else { return }
      value.withCString { pointer in
        ghostty_surface_complete_clipboard_request(surface, pointer, state, false)
      }
    }
  }

  private nonisolated static func confirmReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    string: UnsafePointer<CChar>?,
    state: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e,
  ) {
    _ = request
    guard let stateBits = state.map({ UInt(bitPattern: $0) }),
      let runtime = runtime(from: userdata),
      let valuePtr = string
    else {
      return
    }
    let value = String(cString: valuePtr)
    MainActor.assumeIsolated {
      guard let state = UnsafeMutableRawPointer(bitPattern: stateBits) else { return }
      guard let surface = runtime.clipboardSurface?.ghosttySurface else { return }
      value.withCString { pointer in
        ghostty_surface_complete_clipboard_request(surface, pointer, state, true)
      }
    }
  }

  private nonisolated static func writeClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    content: UnsafePointer<ghostty_clipboard_content_s>?,
    len: Int,
    confirm: Bool,
  ) {
    _ = userdata
    guard let content, len > 0 else { return }

    let items: [(mime: String, data: String)] = (0 ..< len).compactMap { index in
      let item = content.advanced(by: index).pointee
      guard let mime = item.mime.flatMap({ String(cString: $0) }),
        let data = item.data.flatMap({ String(cString: $0) })
      else {
        return nil
      }
      return (mime: mime, data: data)
    }

    if items.isEmpty {
      return
    }

    MainActor.assumeIsolated {
      writeClipboard(location: location, items: items, confirm)
    }
  }

  private nonisolated static func closeSurfaceCallback(userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
    guard let runtime = runtime(from: userdata) else { return }
    if processAlive {
      _ = runtime
    }
  }

  private nonisolated static func writeClipboard(
    location: ghostty_clipboard_e,
    items: [(mime: String, data: String)],
    _ confirm: Bool,
  ) {
    _ = location
    _ = confirm
    let pasteboard = UIPasteboard.general

    if items.isEmpty {
      pasteboard.string = ""
      return
    }

    for item in items where item.mime == "text/plain" {
      pasteboard.string = item.data
      return
    }

    var payload: [[String: Any]] = []
    for item in items {
      if let type = UTType(item.mime) {
        payload.append([type.identifier: item.data.data(using: .utf8) ?? Data()])
      }
    }
    if !payload.isEmpty {
      pasteboard.items = payload
    }
  }

  private static func loadConfig() -> ghostty_config_t? {
    guard let config = ghostty_config_new() else { return nil }
    ghostty_config_load_default_files(config)
    ghostty_config_load_recursive_files(config)
    ghostty_config_load_cli_args(config)
    ghostty_config_finalize(config)
    return config
  }
}

@MainActor
final class MobileGhosttySurfaceView: UIView, MobileGhosttySurfaceActionHandling {
  private let runtime: MobileGhosttyRuntime
  private(set) var ghosttySurface: ghostty_surface_t?
  private let shellCommand: String
  private let tapGestureRecognizer: UITapGestureRecognizer
  private var drawDisplayLink: CADisplayLink?
  private var wasFocused = false
  private(set) var terminalTitle = "SSH"
  var onTitleChange: ((String) -> Void)?
  var onCloseRequest: ((Bool) -> Void)?

  init(runtime: MobileGhosttyRuntime, shellCommand: String) {
    self.runtime = runtime
    self.shellCommand = shellCommand
    tapGestureRecognizer = UITapGestureRecognizer()
    super.init(frame: .zero)
    tapGestureRecognizer.addTarget(self, action: #selector(requestFocus))
    addGestureRecognizer(tapGestureRecognizer)
    backgroundColor = UIColor.black

    runtime.registerClipboardSurface(self)
    initializeSurface()
  }

  deinit {
    MainActor.assumeIsolated {
      runtime.unregisterClipboardSurface(self)
      stopDrawing()
      guard let surface = ghosttySurface else { return }
      ghostty_surface_free(surface)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override class var layerClass: AnyClass {
    CAMetalLayer.self
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if ghosttySurface == nil {
      initializeSurface()
    }

    sizeDidChange(frame.size)
    if window != nil {
      setSurfaceFocus(true)
      _ = becomeFirstResponder()
      beginDrawing()
    } else {
      setSurfaceFocus(false)
      _ = resignFirstResponder()
      stopDrawing()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    sizeDidChange(bounds.size)
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result {
      setSurfaceFocus(true)
    }
    return result
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result {
      setSurfaceFocus(false)
    }
    return result
  }

  override var canBecomeFirstResponder: Bool {
    true
  }

  @objc private func requestFocus() {
    _ = becomeFirstResponder()
  }

  func activateInput() {
    requestFocus()
  }

  func deactivateInput() {
    _ = resignFirstResponder()
  }

  func sizeDidChange(_ size: CGSize) {
    guard let surface = ghosttySurface else { return }
    let scale = max(contentScaleFactor, 1)
    ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
    let width = max(1, UInt32(size.width * scale))
    let height = max(1, UInt32(size.height * scale))
    ghostty_surface_set_size(surface, width, height)
  }

  func requestClose() {
    guard let surface = ghosttySurface else { return }
    ghostty_surface_request_close(surface)
  }

  private func initializeSurface() {
    guard let app = runtime.app, ghosttySurface == nil else {
      return
    }
    var config = ghostty_surface_config_new()
    config.userdata = Unmanaged.passUnretained(self).toOpaque()
    config.platform_tag = GHOSTTY_PLATFORM_IOS
    config.platform = ghostty_platform_u(
      ios: ghostty_platform_ios_s(
        uiview: Unmanaged.passUnretained(self).toOpaque()
      )
    )
    config.scale_factor = UIScreen.main.scale

    shellCommand.withCString { command in
      config.command = command
      ghosttySurface = ghostty_surface_new(app, &config)
    }
  }

  private func setSurfaceFocus(_ focused: Bool) {
    guard let surface = ghosttySurface else { return }
    guard wasFocused != focused else { return }
    wasFocused = focused
    ghostty_surface_set_focus(surface, focused)
  }

  private func sendText(_ text: String) {
    guard let surface = ghosttySurface else { return }
    let utf8Count = text.utf8CString.count
    if utf8Count <= 1 {
      return
    }
    text.withCString { pointer in
      ghostty_surface_text(surface, pointer, UInt(utf8Count - 1))
    }
  }

  private func sendDelete() {
    sendText("\u{7f}")
  }

  private func sendKey(
    key: ghostty_input_key_e,
    action: ghostty_input_action_e,
    mods: ghostty_input_mods_e,
    text: String?,
  ) {
    guard let surface = ghosttySurface else { return }
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = action
    keyEvent.mods = mods
    keyEvent.consumed_mods = mods
    keyEvent.keycode = UInt32(key.rawValue)
    keyEvent.unshifted_codepoint = text?.unicodeScalars.first?.value ?? 0

    if let text {
      _ = text.withCString { pointer in
        keyEvent.text = pointer
        return ghostty_surface_key(surface, keyEvent)
      }
    } else {
      keyEvent.text = nil
      _ = ghostty_surface_key(surface, keyEvent)
    }
  }

  func handleRuntimeAction(_ action: ghostty_action_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE:
      guard let title = action.action.set_title.title else { return true }
      let value = String(cString: title)
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        terminalTitle = trimmed
        onTitleChange?(trimmed)
      }
      return true
    case GHOSTTY_ACTION_COMMAND_FINISHED, GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      onCloseRequest?(false)
      return true
    case GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD:
      _ = becomeFirstResponder()
      return true
    default:
      return false
    }
  }

  private func keyForUsage(_ usage: UIKeyboardHIDUsage) -> ghostty_input_key_e? {
    switch usage {
    case .keyboardUpArrow:
      GHOSTTY_KEY_ARROW_UP
    case .keyboardDownArrow:
      GHOSTTY_KEY_ARROW_DOWN
    case .keyboardLeftArrow:
      GHOSTTY_KEY_ARROW_LEFT
    case .keyboardRightArrow:
      GHOSTTY_KEY_ARROW_RIGHT
    case .keyboardDeleteOrBackspace:
      GHOSTTY_KEY_BACKSPACE
    case .keyboardReturnOrEnter:
      GHOSTTY_KEY_ENTER
    case .keyboardEscape:
      GHOSTTY_KEY_ESCAPE
    case .keyboardTab:
      GHOSTTY_KEY_TAB
    case .keyboardHome:
      GHOSTTY_KEY_HOME
    case .keyboardEnd:
      GHOSTTY_KEY_END
    case .keyboardPageUp:
      GHOSTTY_KEY_PAGE_UP
    case .keyboardPageDown:
      GHOSTTY_KEY_PAGE_DOWN
    default:
      nil
    }
  }

  private func modifiers(for flags: UIKeyModifierFlags) -> ghostty_input_mods_e {
    var value = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) {
      value |= GHOSTTY_MODS_SHIFT.rawValue
    }
    if flags.contains(.control) {
      value |= GHOSTTY_MODS_CTRL.rawValue
    }
    if flags.contains(.alternate) {
      value |= GHOSTTY_MODS_ALT.rawValue
    }
    if flags.contains(.command) {
      value |= GHOSTTY_MODS_SUPER.rawValue
    }
    if flags.contains(.alphaShift) {
      value |= GHOSTTY_MODS_CAPS.rawValue
    }
    return ghostty_input_mods_e(value)
  }

  private func beginDrawing() {
    guard drawDisplayLink == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(drawSurfaceFrame))
    link.add(to: .main, forMode: .common)
    drawDisplayLink = link
  }

  private func stopDrawing() {
    drawDisplayLink?.invalidate()
    drawDisplayLink = nil
  }

  @objc private func drawSurfaceFrame() {
    guard let surface = ghosttySurface else { return }
    ghostty_surface_draw(surface)
  }

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    var handled = false
    for press in presses {
      guard let key = press.key else { continue }
      if let mapped = keyForUsage(key.keyCode) {
        let mods = modifiers(for: key.modifierFlags)
        let action: ghostty_input_action_e = GHOSTTY_ACTION_PRESS
        sendKey(
          key: mapped,
          action: action,
          mods: mods,
          text: nil,
        )
        handled = true
        continue
      }
      let text = key.characters
      if !text.isEmpty {
        sendText(text)
        handled = true
      }
    }

    if !handled {
      super.pressesBegan(presses, with: event)
    }
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    for press in presses {
      guard let key = press.key, let mapped = keyForUsage(key.keyCode) else { continue }
      sendKey(
        key: mapped,
        action: GHOSTTY_ACTION_RELEASE,
        mods: modifiers(for: key.modifierFlags),
        text: nil,
      )
    }
    super.pressesEnded(presses, with: event)
  }
}

extension MobileGhosttySurfaceView: UIKeyInput {
  var hasText: Bool {
    true
  }

  func insertText(_ text: String) {
    sendText(text)
  }

  func deleteBackward() {
    sendDelete()
  }
}

extension MobileGhosttySurfaceView: UITextInputTraits {
  var keyboardType: UIKeyboardType { .default }
  var autocorrectionType: UITextAutocorrectionType { .no }
  var spellCheckingType: UITextSpellCheckingType { .no }
}

struct MobileGhosttySurfaceViewRepresentable: UIViewRepresentable {
  let surfaceView: MobileGhosttySurfaceView

  func makeUIView(context: Context) -> MobileGhosttySurfaceView {
    surfaceView
  }

  func updateUIView(_ uiView: MobileGhosttySurfaceView, context: Context) {}
}
