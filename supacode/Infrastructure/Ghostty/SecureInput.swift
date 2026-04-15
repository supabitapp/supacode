import Carbon
import Cocoa
import SupacodeSettingsShared

@MainActor
final class SecureInput: Observable {
  static let shared = SecureInput()

  private static let logger = SupaLogger("SecureInput")

  var global: Bool = false {
    didSet { apply() }
  }

  private var scoped: [ObjectIdentifier: Bool] = [:]
  private(set) var enabled: Bool = false

  private var desired: Bool {
    global || scoped.contains(where: { $0.value })
  }

  private init() {
    let center = NotificationCenter.default
    center.addObserver(
      self,
      selector: #selector(onDidResignActive(notification:)),
      name: NSApplication.didResignActiveNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(onDidBecomeActive(notification:)),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  isolated deinit {
    NotificationCenter.default.removeObserver(self)
    scoped.removeAll()
    global = false
    apply()
  }

  func setScoped(_ object: ObjectIdentifier, focused: Bool) {
    scoped[object] = focused
    apply()
  }

  func removeScoped(_ object: ObjectIdentifier) {
    scoped[object] = nil
    apply()
  }

  private nonisolated func apply() {
    MainActor.assumeIsolated {
      guard NSApp.isActive else { return }
      guard enabled != desired else { return }

      let err: OSStatus
      if enabled {
        err = DisableSecureEventInput()
      } else {
        err = EnableSecureEventInput()
      }
      if err == noErr {
        enabled = desired
        Self.logger.debug("secure input state=\(self.enabled)")
        return
      }

      Self.logger.warning("secure input apply failed err=\(err)")
    }
  }

  @objc private func onDidBecomeActive(notification: NSNotification) {
    guard !enabled && desired else { return }
    let err = EnableSecureEventInput()
    if err == noErr {
      enabled = true
      Self.logger.debug("secure input enabled on activation")
      return
    }
    Self.logger.warning("secure input apply failed err=\(err)")
  }

  @objc private func onDidResignActive(notification: NSNotification) {
    guard enabled else { return }
    let err = DisableSecureEventInput()
    if err == noErr {
      enabled = false
      Self.logger.debug("secure input disabled on deactivation")
      return
    }
    Self.logger.warning("secure input apply failed err=\(err)")
  }
}
