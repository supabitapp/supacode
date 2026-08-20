import ComposableArchitecture
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureSettingsSelectionTests {
  @Test func repositoriesChangedForwardsRepositorySummaries() async {
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "Repo",
      worktrees: []
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(reconciledRepositories: [repository]),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.repositories(.delegate(.repositoriesChanged([repository]))))
    await store.receive(\.settings.repositoriesChanged) {
      $0.settings.repositorySummaries = [
        SettingsRepositorySummary(id: repository.id.rawValue, name: repository.name)
      ]
    }
    await store.receive(\.commandPalette.pruneRecency)
  }

  /// A remote repo's id is a `remote:` key, not a path, so the summary must
  /// carry the real remote root URL, otherwise the settings pane keys per-repo
  /// settings off a bogus URL and the worktree never sees its scripts.
  @Test func repositoriesChangedForwardsRemoteSummaryWithRealRootURL() async {
    let config = TestRemoteRepo(
      host: RemoteHost(alias: "devbox"),
      remotePath: "/home/me/proj",
      displayName: "proj"
    )
    let repoID = RepositoriesFeature.remoteRepositoryID(for: config)
    let remote = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: "/home/me/proj"),
      name: "proj",
      worktrees: [],
      isGitRepository: true,
      host: config.host
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(reconciledRepositories: [remote]),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.repositories(.delegate(.repositoriesChanged([remote]))))
    await store.receive(\.settings.repositoriesChanged) {
      $0.settings.repositorySummaries = [
        SettingsRepositorySummary(
          id: repoID.rawValue,
          name: "proj",
          isGitRepository: true,
          host: config.host,
          rootURL: URL(fileURLWithPath: "/home/me/proj")
        )
      ]
    }
    await store.receive(\.commandPalette.pruneRecency)
  }

  /// A "Customize Appearance" title overrides the directory name in the
  /// settings sidebar, otherwise identically-named repos are
  /// indistinguishable there.
  @Test func repositoriesChangedResolvesCustomSidebarTitle() async {
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: []
    )
    var repositoriesState = RepositoriesFeature.State(reconciledRepositories: [repository])
    repositoriesState.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id] = .init(title: "Backend")
    }
    // Production seeds every cache on the roster load; keep the state under
    // test consistent so the send below has no stale-cache diff.
    repositoriesState.applyPostReduceCacheRecomputes()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.repositories(.delegate(.repositoriesChanged([repository]))))
    await store.receive(\.settings.repositoriesChanged) {
      $0.settings.repositorySummaries = [
        SettingsRepositorySummary(id: repository.id.rawValue, name: "Backend")
      ]
    }
    await store.receive(\.commandPalette.pruneRecency)
  }

  /// Saving a customization never fires `repositoriesChanged`, so the
  /// summaries must be re-sent from the save itself — with the new title,
  /// since the save's sidebar write lands after AppFeature's handler runs.
  @Test func customizationSaveRefreshesSummariesWithNewTitle() async {
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: []
    )
    var repositoriesState = RepositoriesFeature.State(reconciledRepositories: [repository])
    repositoriesState.repositoryCustomization = RepositoryCustomizationFeature.State(
      repositoryID: repository.id,
      defaultName: repository.name,
      title: "",
      color: nil
    )
    repositoriesState.applyPostReduceCacheRecomputes()
    var settingsState = SettingsFeature.State()
    settingsState.repositorySummaries = [
      SettingsRepositorySummary(id: repository.id.rawValue, name: repository.name)
    ]
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: settingsState
      )
    ) {
      AppFeature()
    }

    await store.send(
      .repositories(
        .repositoryCustomization(
          .presented(.delegate(.save(repositoryID: repository.id, title: "Backend", color: nil)))
        )
      )
    ) {
      $0.repositories.repositoryCustomization = nil
      $0.repositories.$sidebar.withLock { sidebar in
        sidebar.sections[repository.id, default: .init()].title = "Backend"
      }
      $0.repositories.applyPostReduceCacheRecomputes()
    }
    await store.receive(\.settings.repositoriesChanged) {
      $0.settings.repositorySummaries = [
        SettingsRepositorySummary(id: repository.id.rawValue, name: "Backend")
      ]
    }
  }
}
