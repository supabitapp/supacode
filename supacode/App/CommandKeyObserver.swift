import AppKit
import SwiftUI

/// Tracks whether the user is currently holding ⌘ or ⌃ so the UI can surface shortcut hints.
@MainActor
@Observable
final class CommandKeyObserver {
  var isPressed: Bool
  private var monitor: Any?
  private var didBecomeActiveObserver: NSObjectProtocol?
  private var didResignActiveObserver: NSObjectProtocol?

  init() {
    isPressed = false
    monitor = nil
    didBecomeActiveObserver = nil
    didResignActiveObserver = nil
    configureObservers()
  }

  private func configureObservers() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      MainActor.assumeIsolated {
        self?.handleCommandKeyChange(isDown: Self.shouldShowShortcuts(for: event.modifierFlags))
      }
      return event
    }
    let center = NotificationCenter.default
    didBecomeActiveObserver = center.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleCommandKeyChange(isDown: Self.shouldShowShortcuts(for: NSEvent.modifierFlags))
      }
    }
    didResignActiveObserver = center.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleCommandKeyChange(isDown: false)
      }
    }
  }

  nonisolated static func shouldShowShortcuts(for modifierFlags: NSEvent.ModifierFlags) -> Bool {
    modifierFlags.contains(.command) || modifierFlags.contains(.control)
  }

  private func handleCommandKeyChange(isDown: Bool) {
    // Flip immediately; consumers fade the visual change in/out themselves.
    isPressed = isDown
  }
}
