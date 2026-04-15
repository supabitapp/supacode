import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

struct UpdateCommands: Commands {
  let store: StoreOf<UpdatesFeature>
  @Shared(.settingsFile) private var settingsFile

  var body: some Commands {
    let checkForUpdates = AppShortcuts.checkForUpdates.effective(from: settingsFile.global.shortcutOverrides)
    CommandGroup(after: .appInfo) {
      Button("Check for Updates...") {
        store.send(.checkForUpdates)
      }
      .appKeyboardShortcut(checkForUpdates)
      .help("Check for Updates (\(checkForUpdates?.display ?? "none"))")
    }
  }
}
