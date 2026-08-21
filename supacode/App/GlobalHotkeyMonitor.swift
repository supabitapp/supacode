import AppKit
import Carbon.HIToolbox
import SupacodeSettingsShared

// Owns the process-wide Carbon hot key that toggles app visibility: one
// `EventHandlerRef` for the app's life, at most one live `EventHotKeyRef` (so
// re-recording can't leak), and a callback that only forwards to `onFired`.
@MainActor
final class GlobalHotkeyMonitor {
  // Fired on the main actor when the registered chord is pressed. The scene
  // installs it (it needs SwiftUI's `openWindow`); the monitor owns no policy.
  var onFired: (@MainActor () -> Void)?

  private var hotKeyRef: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  // False when `InstallEventHandler` failed: presses would never be delivered,
  // so registration must refuse rather than report a phantom success.
  private var isHandlerInstalled = false

  private static let logger = SupaLogger("GlobalHotkey")
  // Identifies our hot key in the shared application event target.
  private static let hotKeyID = EventHotKeyID(signature: fourCharCode("SPCD"), id: 1)

  init() {
    installEventHandler()
  }

  // Registers `override` as the global chord, replacing any prior one. A nil or
  // disabled override just clears it. Returns false when Carbon refuses the
  // registration (e.g. the chord is already claimed system-wide).
  @discardableResult
  func apply(_ override: AppShortcutOverride?) -> Bool {
    unregister()
    guard let override, override.isEnabled else { return true }
    guard isHandlerInstalled else {
      Self.logger.error("Refusing to register \(override.displayString): the event handler never installed.")
      return false
    }
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(override.keyCode),
      override.carbonModifierFlags,
      Self.hotKeyID,
      GetApplicationEventTarget(),
      0,
      &ref
    )
    guard status == noErr, let ref else {
      Self.logger.error("RegisterEventHotKey failed with status \(status) for \(override.displayString).")
      hotKeyRef = nil
      return false
    }
    hotKeyRef = ref
    return true
  }

  // Releases the global registration and the shared handler explicitly at
  // termination, ahead of the deinit's own backstop cleanup.
  func tearDown() {
    unregister()
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }

  isolated deinit {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    if let eventHandler { RemoveEventHandler(eventHandler) }
  }

  private func unregister() {
    guard let hotKeyRef else { return }
    UnregisterEventHotKey(hotKeyRef)
    self.hotKeyRef = nil
  }

  private func installEventHandler() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let callback: EventHandlerUPP = { _, event, userData in
      guard let userData, let event else { return OSStatus(eventNotHandledErr) }
      var pressedID = EventHotKeyID()
      let status = GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &pressedID
      )
      guard status == noErr, pressedID.id == GlobalHotkeyMonitor.hotKeyID.id else {
        return OSStatus(eventNotHandledErr)
      }
      // Carbon delivers on the main run loop, so the monitor is already isolated.
      MainActor.assumeIsolated {
        let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
        guard let onFired = monitor.onFired else {
          GlobalHotkeyMonitor.logger.error("Hotkey fired before the scene wired its sink; press dropped.")
          return
        }
        onFired()
      }
      return noErr
    }
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      callback,
      1,
      &spec,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler
    )
    guard status == noErr else {
      Self.logger.error("InstallEventHandler failed with status \(status); the global hotkey is inert.")
      return
    }
    isHandlerInstalled = true
  }

  private static func fourCharCode(_ string: String) -> FourCharCode {
    var code: FourCharCode = 0
    for scalar in string.unicodeScalars.prefix(4) {
      code = (code << 8) + FourCharCode(scalar.value & 0xFF)
    }
    return code
  }
}
