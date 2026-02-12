import ComposableArchitecture
import SwiftUI

struct SidebarFooterView: View {
  let store: StoreOf<RepositoriesFeature>
  @Environment(\.openURL) private var openURL
  @Environment(CommandKeyObserver.self) private var commandKeyObserver

  var body: some View {
    HStack {
      Button {
        store.send(.setOpenPanelPresented(true))
      } label: {
        HStack(spacing: 6) {
          Label("Add Repository", systemImage: "folder.badge.plus")
            .font(.callout)
          if commandKeyObserver.isPressed {
            ShortcutHintView(text: AppShortcuts.openRepository.display, color: .secondary)
          }
        }
      }
      .help("Add Repository (\(AppShortcuts.openRepository.display))")
      Spacer()
      Menu {
        Button("Submit GitHub issue", systemImage: "exclamationmark.bubble") {
          if let url = URL(string: "https://github.com/supabitapp/supacode/issues/new") {
            openURL(url)
          }
        }
        .help("Submit GitHub issue")
      } label: {
        Label("Help", systemImage: "questionmark.circle")
          .labelStyle(.iconOnly)
      }
      .menuIndicator(.hidden)
      .help("Help")
      Button {
        store.send(.refreshWorktrees)
      } label: {
        Image(systemName: "arrow.clockwise")
          .symbolEffect(.rotate, options: .repeating, isActive: store.state.isRefreshingWorktrees)
          .accessibilityLabel("Refresh Worktrees")
      }
      .help("Refresh Worktrees (\(AppShortcuts.refreshWorktrees.display))")
      .disabled(store.state.repositoryRoots.isEmpty && !store.state.isRefreshingWorktrees)
      Button {
        store.send(.selectArchivedWorktrees)
      } label: {
        Image(systemName: "archivebox")
          .accessibilityLabel("Archived Worktrees")
      }
      .help("Archived Worktrees (\(AppShortcuts.archivedWorktrees.display))")
      Button("Settings", systemImage: "gearshape") {
        SettingsWindowManager.shared.show()
      }
      .labelStyle(.iconOnly)
      .help("Settings (\(AppShortcuts.openSettings.display))")
    }
    .buttonStyle(.plain)
    .font(.callout)
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
  }
}
