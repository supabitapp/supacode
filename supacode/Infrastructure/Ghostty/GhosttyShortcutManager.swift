import GhosttyKit
import Observation
import SupacodeSettingsShared
import SwiftUI

@MainActor
@Observable
final class GhosttyShortcutManager {
  private let runtime: GhosttyRuntime
  private var generation: Int = 0

  init(runtime: GhosttyRuntime) {
    self.runtime = runtime
    runtime.onConfigChange = { [weak self] in
      self?.refresh()
    }
  }

  func refresh() {
    generation += 1
  }

  var commandPaletteEntries: [GhosttyCommand] {
    _ = generation
    return runtime.commandPaletteEntries()
  }

  func keyboardShortcut(for action: String) -> KeyboardShortcut? {
    _ = generation
    return runtime.keyboardShortcut(for: action)
  }

  func display(for action: String) -> String? {
    guard let shortcut = keyboardShortcut(for: action) else { return nil }
    return shortcut.display
  }

  // Display strings for terminal actions that have app-level menu bindings.
  var reservedDisplayStrings: Set<String> {
    _ = generation
    return Set(Self.terminalActions.compactMap { display(for: $0) })
  }

  private static let terminalActions = [
    "new_tab", "close_surface", "close_tab",
    "start_search", "search:next", "search:previous", "end_search", "search_selection",
  ]
}
