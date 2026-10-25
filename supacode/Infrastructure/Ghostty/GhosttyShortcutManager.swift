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
  private var configInputsSubscription: AnyCancellable?

  init(runtime: GhosttyRuntime) {
    self.runtime = runtime
    runtime.onConfigChange = { [weak self] in
      self?.refresh()
    }
    // Reload here, not in a window's view tree, so settings that feed the
    // generated config apply even while no window is open. A nonisolated
    // initializer keeps the transform off the main actor: the publisher emits
    // off it, so an inline closure here would trap before the receive(on:) hop.
    configInputsSubscription = $settingsFile.publisher
      .map(GhosttyConfigInputs.init)
      .removeDuplicates()
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak runtime] _ in
        MainActor.assumeIsolated {
          runtime?.reloadAppConfig()
        }
      }
  }

  nonisolated deinit {}

  func refresh() {
    generation += 1
  }

  /// Reloads the generated Ghostty config now, e.g. after the user creates their
  /// Supacode config so it takes effect without a relaunch.
  func reloadConfig() {
    runtime.reloadAppConfig()
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

/// The settings that feed the generated Ghostty config; any change reloads it.
nonisolated struct GhosttyConfigInputs: Equatable {
  let shortcutOverrides: [AppShortcutID: AppShortcutOverride]
  let themeSyncEnabled: Bool
  let backgroundTransparent: Bool
  let userConfigMode: GhosttyUserConfigMode

  init(_ settingsFile: SettingsFile) {
    shortcutOverrides = settingsFile.global.shortcutOverrides
    themeSyncEnabled = settingsFile.global.terminalThemeSyncEnabled
    backgroundTransparent = settingsFile.global.resolvedTerminalBackgroundTransparency
    userConfigMode = settingsFile.global.ghosttyUserConfigMode
  }
}
