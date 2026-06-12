import ComposableArchitecture
import Kingfisher
import SupacodeSettingsFeature
import SwiftUI

/// Sidebar label that shows a GitHub owner avatar next to the
/// repository name. Falls back to a git-branch symbol for git repos
/// without an avatar and to a folder symbol for non-git folder
/// entries.
private struct RepositoryLabel: View {
  let name: String
  let rootURL: URL
  let isGitRepository: Bool

  @State private var avatarURL: URL?
  @Dependency(GitClientDependency.self) private var gitClient

  var body: some View {
    Label {
      Text(name)
    } icon: {
      if isGitRepository {
        KFImage(avatarURL)
          .placeholder {
            Image(systemName: "arrow.trianglehead.branch")
              .padding(-3)
              .accessibilityHidden(true)
          }
          .resizable()
          .aspectRatio(1, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
          .padding(3)
      } else {
        Image(systemName: "folder")
          .accessibilityHidden(true)
      }
    }
    .task(id: rootURL) {
      guard isGitRepository else {
        avatarURL = nil
        return
      }
      avatarURL = await GitHubOwnerAvatar.url(for: rootURL, gitClient: gitClient)
    }
  }
}

/// Disclosure group label for a repository in the settings sidebar.
private struct RepositoryDisclosureLabel: View {
  let repository: SettingsRepositorySummary
  @Bindable var settingsStore: StoreOf<SettingsFeature>
  @Binding var isExpanded: Bool

  private var isSelected: Bool {
    settingsStore.selection?.repositoryID == repository.id
  }

  var body: some View {
    RepositoryLabel(
      name: repository.name,
      rootURL: repository.rootURL,
      isGitRepository: repository.isGitRepository
    )
    .contentShape(Rectangle())
    .accessibilityAddTraits(.isButton)
    .onTapGesture {
      guard !isSelected else {
        isExpanded.toggle()
        return
      }
      _ = settingsStore.send(.setSelection(.repository(repository.id)))
    }
  }
}

/// One repository row in the settings sidebar. Git repos get a General /
/// Scripts disclosure; folder repos go straight to Scripts. Shared by the
/// Local and Remote sections so the two render identically.
private struct SettingsRepositoryRow: View {
  let repository: SettingsRepositorySummary
  @Bindable var settingsStore: StoreOf<SettingsFeature>
  @Binding var expandedRepositories: Set<String>

  var body: some View {
    if repository.isGitRepository {
      let isExpanded = Binding(
        get: { expandedRepositories.contains(repository.id) },
        set: { expanded in
          if expanded {
            expandedRepositories.insert(repository.id)
          } else {
            expandedRepositories.remove(repository.id)
          }
        }
      )
      DisclosureGroup(isExpanded: isExpanded) {
        Label("General", systemImage: "gearshape")
          .tag(SettingsSection.repository(repository.id))
        Label("Scripts", systemImage: "terminal")
          .tag(SettingsSection.repositoryScripts(repository.id))
      } label: {
        RepositoryDisclosureLabel(
          repository: repository,
          settingsStore: settingsStore,
          isExpanded: isExpanded
        )
      }
    } else {
      // Folder entries go straight to the scripts page; no general
      // disclosure row since the git settings don't apply. Selection is
      // expressed via the row tag so selecting it updates the selection.
      RepositoryLabel(
        name: repository.name,
        rootURL: repository.rootURL,
        isGitRepository: false
      )
      .tag(SettingsSection.repositoryScripts(repository.id))
    }
  }
}

/// Sidebar content for the settings split view.
private struct SettingsSidebarView: View {
  @Bindable var settingsStore: StoreOf<SettingsFeature>
  @Binding var expandedRepositories: Set<String>

  var body: some View {
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
      Label("Global Scripts", systemImage: "terminal")
        .tag(SettingsSection.scripts)
      Label("Updates", systemImage: "arrow.down.circle")
        .tag(SettingsSection.updates)

      let localRepositories = settingsStore.repositorySummaries.filter { !$0.isRemote }
      let remoteRepositories = settingsStore.repositorySummaries.filter(\.isRemote)
      if !localRepositories.isEmpty {
        Section("Local") {
          ForEach(localRepositories, id: \.id) { repository in
            SettingsRepositoryRow(
              repository: repository,
              settingsStore: settingsStore,
              expandedRepositories: $expandedRepositories
            )
          }
        }
      }
      if !remoteRepositories.isEmpty {
        Section("Remote") {
          ForEach(remoteRepositories, id: \.id) { repository in
            SettingsRepositoryRow(
              repository: repository,
              settingsStore: settingsStore,
              expandedRepositories: $expandedRepositories
            )
          }
        }
      }
    }
    .listStyle(.sidebar)
    .frame(minWidth: 220, maxHeight: .infinity)
    .navigationSplitViewColumnWidth(220)
    .toolbar(removing: .sidebarToggle)
  }
}

/// Detail pane content for the settings split view.
private struct SettingsDetailView: View {
  let selection: SettingsSection
  let selectedRepositorySummary: SettingsRepositorySummary?
  @Bindable var settingsStore: StoreOf<SettingsFeature>
  let updatesStore: StoreOf<UpdatesFeature>

  var body: some View {
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
    case .scripts:
      GlobalScriptsSettingsView(store: settingsStore)
        .navigationTitle("Global Scripts")
    case .repository:
      if let repository = selectedRepositorySummary {
        if let repositorySettingsStore = settingsStore.scope(
          state: \.repositorySettings,
          action: \.repositorySettings
        ) {
          RepositorySettingsView(store: repositorySettingsStore)
            .id(repository.id)
            .navigationTitle(repository.name)
        } else {
          ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(repository.name)
        }
      } else {
        Text("Repository not found.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .navigationTitle("Repositories")
      }
    case .repositoryScripts:
      if let repository = selectedRepositorySummary {
        if let repositorySettingsStore = settingsStore.scope(
          state: \.repositorySettings,
          action: \.repositorySettings
        ) {
          RepositoryScriptsSettingsView(store: repositorySettingsStore)
            .id("\(repository.id)-scripts")
            // Em dash is the deliberate visual separator for the settings nav title.
            .navigationTitle("\(repository.name) — Scripts")
        } else {
          ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Em dash is the deliberate visual separator for the settings nav title.
            .navigationTitle("\(repository.name) — Scripts")
        }
      } else {
        Text("Repository not found.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .navigationTitle("Scripts")
      }
    }
  }
}

struct SettingsView: View {
  @Bindable var store: StoreOf<AppFeature>
  @Bindable var settingsStore: StoreOf<SettingsFeature>
  @State private var expandedRepositories: Set<String> = []

  init(store: StoreOf<AppFeature>) {
    self.store = store
    settingsStore = store.scope(state: \.settings, action: \.settings)
  }

  var body: some View {
    let updatesStore = store.scope(state: \.updates, action: \.updates)
    let selection = settingsStore.selection ?? .general
    let selectedRepositorySummary: SettingsRepositorySummary? = {
      guard let repositoryID = selection.repositoryID else {
        return nil
      }
      return settingsStore.repositorySummaries.first(where: { $0.id == repositoryID })
    }()

    NavigationSplitView(columnVisibility: .constant(.all)) {
      SettingsSidebarView(
        settingsStore: settingsStore,
        expandedRepositories: $expandedRepositories
      )
      .onChange(of: selection, initial: true) { _, newSelection in
        guard let repositoryID = newSelection.repositoryID else { return }
        expandedRepositories.insert(repositoryID)
      }
    } detail: {
      SettingsDetailView(
        selection: selection,
        selectedRepositorySummary: selectedRepositorySummary,
        settingsStore: settingsStore,
        updatesStore: updatesStore
      )
    }
    .toolbar {
      // Invisible item keeps the toolbar stable when switching between
      // detail views with and without toolbar items.
      ToolbarItem(placement: .principal) {
        Color.clear.frame(width: 0, height: 0)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .alert($settingsStore.scope(state: \.alert, action: \.alert))
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
