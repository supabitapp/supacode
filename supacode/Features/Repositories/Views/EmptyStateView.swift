import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

struct EmptyStateView: View {
  let store: StoreOf<RepositoriesFeature>
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let openRepo = AppShortcuts.openRepository.effective(from: settingsFile.global.shortcutOverrides)
    let hint: String =
      AppShortcut.display(of: openRepo).map { "Press \($0) or click Open Repository or Folder to choose one." }
      ?? "Click Open Repository or Folder to choose one."

    VStack(spacing: 12) {
      Image(systemName: "tray")
        .appFont(.title)
        .imageScale(.large)
        .accessibilityHidden(true)
        .foregroundStyle(.secondary)
      VStack(spacing: 4) {
        Text("Open a repository or folder")
          .appFont(.title3)
        Text(hint)
          .appFont(.subheadline)
          .foregroundStyle(.secondary)
      }
      Button("Open Repository or Folder...") {
        store.send(.setOpenPanelPresented(true))
      }
      .appKeyboardShortcut(openRepo)
      .help(AppShortcut.helpText("Open Repository or Folder", shortcut: openRepo))
      Button("Add Remote Repository…") {
        store.send(.requestAddRemoteRepository)
      }
      .buttonStyle(.link)
      .help("Add a repository or folder on an SSH host")
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
