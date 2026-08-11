import Combine
import GhosttyKit
import Observation
import Sharing
import SupacodeSettingsShared
import SwiftUI

@MainActor
@Observable
final class GhosttyShortcutManager {
  private let runtime: GhosttyRuntime
  private var generation: Int = 0
  @ObservationIgnored
  @Shared(.settingsFile) private var settingsFile: SettingsFile
  @ObservationIgnored
  private var overridesSubscription: AnyCancellable?

  init(runtime: GhosttyRuntime) {
    self.runtime = runtime
    runtime.onConfigChange = { [weak self] in
      self?.refresh()
    }
    // Rebinding a shortcut regenerates the app's unbind config lines; reload
    // here, not in a window's view tree, so the terminal releases the new
    // chord even while no window is open.
    overridesSubscription = $settingsFile.publisher
      .map(\.global.shortcutOverrides)
      .removeDuplicates()
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak runtime] _ in
        MainActor.assumeIsolated {
          runtime?.reloadAppConfig()
        }
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

}
