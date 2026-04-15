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
        repositories: RepositoriesFeature.State(repositories: [repository]),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.repositories(.delegate(.repositoriesChanged([repository]))))
    await store.receive(\.settings.repositoriesChanged) {
      $0.settings.repositorySummaries = [
        SettingsRepositorySummary(id: repository.id, name: repository.name)
      ]
    }
    await store.receive(\.commandPalette.pruneRecency)
  }
}
