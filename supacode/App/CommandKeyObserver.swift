import AppKit
import SwiftUI

/// Tracks whether the user is currently holding ⌘ or ⌃ so the UI can surface
/// shortcut hints. The two modifiers are tracked independently: the tab bar
/// hints on ⌘ (tab selection is ⌘1..⌘9) while the sidebar hints on ⌃ (worktree
/// selection is ⌃1..⌃0). A single "either modifier" flag would surface the
/// wrong hints — e.g. ⌘ lighting up the ⌃-based worktree hints.
@MainActor
@Observable
final class CommandKeyObserver {
  var isCommandPressed: Bool
  var isControlPressed: Bool
  private var monitor: Any?
  private var didBecomeActiveObserver: NSObjectProtocol?
  private var didResignActiveObserver: NSObjectProtocol?

  init() {
    isCommandPressed = false
    isControlPressed = false
    monitor = nil
    didBecomeActiveObserver = nil
    didResignActiveObserver = nil
    configureObservers()
  }

  private func configureObservers() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      MainActor.assumeIsolated {
        self?.update(for: event.modifierFlags)
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
        self?.update(for: NSEvent.modifierFlags)
      }
    }
    didResignActiveObserver = center.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.update(for: [])
      }
    }
  }

  nonisolated static func isCommandActive(for modifierFlags: NSEvent.ModifierFlags) -> Bool {
    modifierFlags.contains(.command)
  }

  nonisolated static func isControlActive(for modifierFlags: NSEvent.ModifierFlags) -> Bool {
    modifierFlags.contains(.control)
  }

  private func update(for modifierFlags: NSEvent.ModifierFlags) {
    // Flip immediately; consumers fade the visual change in/out themselves.
    isCommandPressed = Self.isCommandActive(for: modifierFlags)
    isControlPressed = Self.isControlActive(for: modifierFlags)
  }
}
