import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

struct EmptyStateView: View {
  let store: StoreOf<RepositoriesFeature>
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let openRepo = AppShortcuts.openRepository.effective(from: settingsFile.global.shortcutOverrides)
    VStack {
      Image(systemName: "tray")
        .font(.title2)
        .accessibilityHidden(true)
      Text("Open a git repository")
        .font(.headline)
      Text(
        "Press \(openRepo?.display ?? AppShortcuts.openRepository.display) "
          + "or click Open Repository to choose a repository."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      Button("Open Repository...") {
        store.send(.setOpenPanelPresented(true))
      }
      .appKeyboardShortcut(openRepo)
      .help("Open Repository (\(openRepo?.display ?? "none"))")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .multilineTextAlignment(.center)
  }
}
