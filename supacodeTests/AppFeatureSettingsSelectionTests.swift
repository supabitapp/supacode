import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
struct AppFeatureSettingsSelectionTests {
  @Test func selectingRepositoryCreatesRepositorySettingsState() async {
    let repository = Repository(
      id: "repo-id",
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

    await store.send(.settings(.setSelection(.repository(repository.id)))) {
      $0.settings.selection = .repository(repository.id)
      $0.settings.repositorySettings = RepositorySettingsFeature.State(
        rootURL: repository.rootURL,
        settings: .default
      )
    }
  }

  @Test func selectingMissingRepositoryClearsRepositorySettingsState() async {
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(repositories: []),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.settings(.setSelection(.repository("missing")))) {
      $0.settings.selection = .repository("missing")
      $0.settings.repositorySettings = nil
    }
  }

  @Test func selectingNonRepositoryClearsRepositorySettingsState() async {
    let repository = Repository(
      id: "repo-id",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "Repo",
      worktrees: []
    )
    var state = AppFeature.State(
      repositories: RepositoriesFeature.State(repositories: [repository]),
      settings: SettingsFeature.State()
    )
    state.settings.selection = .repository(repository.id)
    state.settings.repositorySettings = RepositorySettingsFeature.State(
      rootURL: repository.rootURL,
      settings: .default
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    }

    await store.send(.settings(.setSelection(.general))) {
      $0.settings.selection = .general
      $0.settings.repositorySettings = nil
    }
  }

  @Test func selectingCodingAgentsClearsRepositorySettingsState() async {
    let repository = Repository(
      id: "repo-id",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "Repo",
      worktrees: []
    )
    var state = AppFeature.State(
      repositories: RepositoriesFeature.State(repositories: [repository]),
      settings: SettingsFeature.State()
    )
    state.settings.selection = .repository(repository.id)
    state.settings.repositorySettings = RepositorySettingsFeature.State(
      rootURL: repository.rootURL,
      settings: .default
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    }

    await store.send(.settings(.setSelection(.codingAgents))) {
      $0.settings.selection = .codingAgents
      $0.settings.repositorySettings = nil
    }
  }
}
