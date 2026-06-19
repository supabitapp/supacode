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
    let config = RemoteRepositoryConfig(
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
}
