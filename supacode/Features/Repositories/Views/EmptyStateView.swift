import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

struct EmptyStateView: View {
  let store: StoreOf<RepositoriesFeature>
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let openRepo = AppShortcuts.openRepository.effective(from: settingsFile.global.shortcutOverrides)

    VStack(spacing: 12) {
      Image(systemName: "tray")
        .font(.title)
        .imageScale(.large)
        .accessibilityHidden(true)
        .foregroundStyle(.secondary)
      VStack(spacing: 4) {
        Text("Open a repository or folder")
          .font(.title3)
        Text(
          "Press \(openRepo?.display ?? AppShortcuts.openRepository.display) "
            + "or click Open Repository or Folder to choose one."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
      Button("Open Repository or Folder...") {
        store.send(.setOpenPanelPresented(true))
      }
      .appKeyboardShortcut(openRepo)
      .help("Open Repository or Folder (\(openRepo?.display ?? "none"))")
    }
    .multilineTextAlignment(.center)
    .background(Color(nsColor: .windowBackgroundColor))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
