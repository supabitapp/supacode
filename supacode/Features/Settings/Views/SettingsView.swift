import ComposableArchitecture
import Kingfisher
import SwiftUI

/// Sidebar label that shows a GitHub owner avatar next to the repository name.
private struct RepositoryLabel: View {
  let name: String
  let rootURL: URL

  @State private var avatarURL: URL?

  var body: some View {
    Label {
      Text(name)
    } icon: {
      KFImage(avatarURL)
        .placeholder {
          Image(systemName: "folder")
            .padding(-3)
            .accessibilityHidden(true)
        }
        .resizable()
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(3)
    }
    .task(id: rootURL) {
      avatarURL = await Self.ownerAvatarURL(for: rootURL)
    }
  }

  private static func ownerAvatarURL(for rootURL: URL) async -> URL? {
    guard let info = await GitClient().remoteInfo(for: rootURL) else {
      return nil
    }
    return URL(string: "https://github.com/\(info.owner).png?size=64")
  }
}

struct SettingsView: View {
  @Bindable var store: StoreOf<AppFeature>
  @Bindable var settingsStore: StoreOf<SettingsFeature>

  init(store: StoreOf<AppFeature>) {
    self.store = store
    settingsStore = store.scope(state: \.settings, action: \.settings)
  }

  var body: some View {
    let updatesStore = store.scope(state: \.updates, action: \.updates)
    let repositories = store.repositories.repositories
    let selection = settingsStore.selection ?? .general

    NavigationSplitView(columnVisibility: .constant(.all)) {
      List(selection: $settingsStore.selection.sending(\.setSelection)) {
        Label("General", systemImage: "gearshape")
          .tag(SettingsSection.general)
        Label("Notifications", systemImage: "bell")
          .tag(SettingsSection.notifications)
        Label("Worktrees", systemImage: "list.dash")
          .tag(SettingsSection.worktree)
        Label("Developer", systemImage: "hammer")
          .tag(SettingsSection.developer)
        Label("GitHub", image: "github-mark")
          .tag(SettingsSection.github)
        Label("Shortcuts", systemImage: "keyboard")
          .tag(SettingsSection.shortcuts)
        Label("Updates", systemImage: "arrow.down.circle")
          .tag(SettingsSection.updates)

        Section("Repositories") {
          ForEach(settingsStore.sortedRepositoryIDs, id: \.self) { repositoryID in
            if let repository = repositories[id: repositoryID] {
              RepositoryLabel(name: repository.name, rootURL: repository.rootURL)
                .tag(SettingsSection.repository(repository.id))
            }
          }
        }
      }
      .listStyle(.sidebar)
      .frame(minWidth: 220, maxHeight: .infinity)
      .navigationSplitViewColumnWidth(220)
      .toolbar(removing: .sidebarToggle)
    } detail: {
      switch selection {
      case .general:
        AppearanceSettingsView(store: settingsStore)
      case .notifications:
        NotificationsSettingsView(store: settingsStore)
      case .worktree:
        WorktreeSettingsView(store: settingsStore)
      case .developer:
        DeveloperSettingsView(store: settingsStore)
      case .shortcuts:
        KeyboardShortcutsSettingsView(store: settingsStore)
      case .updates:
        UpdatesSettingsView(settingsStore: settingsStore, updatesStore: updatesStore)
      case .github:
        GithubSettingsView(store: settingsStore)
      case .repository(let repositoryID):
        if let repository = repositories[id: repositoryID] {
          IfLetStore(
            settingsStore.scope(state: \.repositorySettings, action: \.repositorySettings)
          ) { repositorySettingsStore in
            RepositorySettingsView(store: repositorySettingsStore)
              .id(repository.id)
              .navigationTitle(repository.name)
          }
        } else {
          Text("Repository not found.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle("Repositories")
        }
      }
    }
    .toolbar {
      // Invisible item keeps the toolbar stable when switching between
      // detail views with and without toolbar items.
      ToolbarItem(placement: .principal) {
        Color.clear.frame(width: 0, height: 0)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .alert(store: settingsStore.scope(state: \.$alert, action: \.alert))
    .alert(store: store.scope(state: \.$alert, action: \.alert))
    .frame(minWidth: 750, minHeight: 500)
    .onAppear {
      guard settingsStore.selection == nil else { return }
      settingsStore.send(.setSelection(.general))
    }
    .onDisappear {
      settingsStore.send(.setSelection(nil))
    }
  }
}
