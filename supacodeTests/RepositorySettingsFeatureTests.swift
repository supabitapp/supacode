import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

@MainActor
struct RepositorySettingsFeatureTests {
  @Test(.dependencies) func applyRepositoryNamePersistsAndNotifies() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo-a")
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.repositoryRoots = [rootURL.path(percentEncoded: false)]
    }

    let store = TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: rootURL,
        settings: .default
      )
    ) {
      RepositorySettingsFeature()
    }

    await store.send(.repositoryNameDraftChanged("workspace-repo")) {
      $0.repositoryNameDraft = "workspace-repo"
    }
    await store.send(.applyRepositoryName) {
      $0.settings.repositoryName = "workspace-repo"
      $0.repositoryNameDraft = "workspace-repo"
      $0.repositoryNameValidationMessage = nil
    }
    await store.receive(\.delegate.repositoryNameChanged)

    @Shared(.repositorySettings(rootURL)) var repositorySettings
    #expect(repositorySettings.repositoryName == "workspace-repo")
  }

  @Test(.dependencies) func applyRepositoryNameRejectsDuplicate() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo-a")
    let otherRootURL = URL(fileURLWithPath: "/tmp/repo-b")
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.repositoryRoots = [
        rootURL.path(percentEncoded: false),
        otherRootURL.path(percentEncoded: false),
      ]
      $0.repositories[otherRootURL.path(percentEncoded: false)] = RepositorySettings(
        repositoryName: "workspace-repo",
        setupScript: "",
        runScript: "",
        openActionID: OpenWorktreeAction.automaticSettingsID,
        worktreeBaseRef: nil,
        copyIgnoredOnWorktreeCreate: false,
        copyUntrackedOnWorktreeCreate: false,
        pullRequestMergeStrategy: .merge
      )
    }

    let store = TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: rootURL,
        settings: .default
      )
    ) {
      RepositorySettingsFeature()
    }

    await store.send(.repositoryNameDraftChanged("workspace-repo")) {
      $0.repositoryNameDraft = "workspace-repo"
    }
    await store.send(.applyRepositoryName) {
      $0.repositoryNameValidationMessage = "Repository name must be unique."
    }
  }

  @Test(.dependencies) func applyRepositoryNameRejectsInvalidCharacters() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo-a")
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.repositoryRoots = [rootURL.path(percentEncoded: false)]
    }

    let store = TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: rootURL,
        settings: .default
      )
    ) {
      RepositorySettingsFeature()
    }

    await store.send(.repositoryNameDraftChanged("bad/name")) {
      $0.repositoryNameDraft = "bad/name"
    }
    await store.send(.applyRepositoryName) {
      $0.repositoryNameValidationMessage = "Repository name contains unsupported characters."
    }
  }

  @Test(.dependencies) func resetRepositoryNameUsesDefaultAndNotifies() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo-a")
    var settings = RepositorySettings.default
    settings.repositoryName = "workspace-repo"
    let store = TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: rootURL,
        settings: settings,
        repositoryNameDraft: "workspace-repo"
      )
    ) {
      RepositorySettingsFeature()
    }

    await store.send(.resetRepositoryNameToDefault) {
      $0.settings.repositoryName = nil
      $0.repositoryNameDraft = "repo-a"
      $0.repositoryNameValidationMessage = nil
    }
    await store.receive(\.delegate.repositoryNameChanged)
  }
}
