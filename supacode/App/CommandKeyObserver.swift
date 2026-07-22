import AppKit
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// Tracks whether the user is currently holding ⌘ or ⌃ so the UI can surface shortcut hints.
@MainActor
@Observable
final class CommandKeyObserver {
  var isPressed: Bool
  /// Slot-aligned Select Tab N chords, resolved here so no tab-bar view body observes the settings file.
  private var tabSelectionHints: [String?]
  private var monitor: Any?
  private var didBecomeActiveObserver: NSObjectProtocol?
  private var didResignActiveObserver: NSObjectProtocol?

  init() {
    isPressed = false
    tabSelectionHints = Self.resolvedTabSelectionHints()
    monitor = nil
    didBecomeActiveObserver = nil
    didResignActiveObserver = nil
    configureObservers()
  }

  func tabSelectionHint(atSlot index: Int) -> String? {
    guard tabSelectionHints.indices.contains(index) else { return nil }
    return tabSelectionHints[index]
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
    // Re-resolve on the way in only: the hints must survive the release so consumers can fade them out.
    if isDown {
      let hints = Self.resolvedTabSelectionHints()
      if hints != tabSelectionHints {
        tabSelectionHints = hints
      }
    }
    // Flip immediately; consumers fade the visual change in/out themselves.
    isPressed = isDown
  }

  private static func resolvedTabSelectionHints() -> [String?] {
    @Shared(.settingsFile) var settingsFile
    return AppShortcuts.tabSelectionShortcutDisplays(overrides: settingsFile.global.shortcutOverrides)
  }
}
