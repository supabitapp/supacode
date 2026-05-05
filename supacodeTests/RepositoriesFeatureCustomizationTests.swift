import ComposableArchitecture
import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared
import SwiftUI
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct RepositoriesFeatureCustomizationTests {
  private let repoID = "/tmp/customize-repo"

  private func makeInitialState(
    isGitRepository: Bool = true,
  ) -> RepositoriesFeature.State {
    let worktree = Worktree(
      id: "\(repoID)/main",
      name: "main",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: repoID),
      repositoryRootURL: URL(fileURLWithPath: repoID),
    )
    let repository = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: repoID),
      name: "customize-repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree]),
      isGitRepository: isGitRepository,
    )
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [repository.rootURL]
    return state
  }

  @Test func requestCustomizeRepositorySeedsPromptFromStoredSidebarSection() async {
    var initial = makeInitialState()
    initial.$sidebar.withLock { sidebar in
      sidebar.sections[self.repoID] = .init(
        title: "Pretty",
        color: .blue,
      )
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeRepository(repoID)) {
      $0.repositoryCustomization = RepositoryCustomizationFeature.State(
        repositoryID: self.repoID,
        defaultName: "customize-repo",
        title: "Pretty",
        color: .blue,
        customColor: RepositoryColor.blue.color,
      )
    }
  }

  @Test func requestCustomizeRepositoryNoOpsForFolderRepos() async {
    // Folder repos render through `SidebarFolderRow` and have no
    // section header to tint. The reducer must reject the request
    // even if a future deeplink or palette entry tries to invoke
    // it.
    let store = TestStore(initialState: makeInitialState(isGitRepository: false)) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeRepository(repoID))
    // No state mutation expected — `repositoryCustomization` stays nil.
  }

  @Test func saveDelegatePersistsTitleAndColorToSidebar() async {
    var initial = makeInitialState()
    initial.repositoryCustomization = RepositoryCustomizationFeature.State(
      repositoryID: repoID,
      defaultName: "customize-repo",
      title: "",
      color: nil,
      customColor: .accentColor,
    )
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoryCustomization(
        .presented(
          .delegate(
            .save(repositoryID: repoID, title: "Renamed", color: .red),
          ))),
    ) {
      $0.repositoryCustomization = nil
      $0.$sidebar.withLock { sidebar in
        sidebar.sections[self.repoID, default: .init()].title = "Renamed"
        sidebar.sections[self.repoID, default: .init()].color = .red
      }
    }
  }

  @Test func explicitRemovalDropsCustomizationFromSidebar() async {
    // `preserveOrphanSections` keeps customized tombstones across
    // transient drops (filesystem flutter), but an explicit "Remove
    // Repository" must purge `sidebar.sections[id]` so re-adding the
    // same path doesn't silently restore the user's old title /
    // color.
    var initial = makeInitialState()
    initial.$sidebar.withLock { sidebar in
      sidebar.sections[self.repoID] = .init(
        title: "Pretty",
        color: .blue,
      )
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.repositoryPersistence.pruneRepositoryConfigs = { _ in }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.repositoriesRemoved([repoID], selectionWasRemoved: false))
    await store.skipReceivedActions()

    #expect(store.state.sidebar.sections[repoID] == nil)
  }

  @Test func cancelDelegateClearsPresentedState() async {
    var initial = makeInitialState()
    initial.repositoryCustomization = RepositoryCustomizationFeature.State(
      repositoryID: repoID,
      defaultName: "customize-repo",
      title: "",
      color: nil,
      customColor: .accentColor,
    )
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoryCustomization(.presented(.delegate(.cancel))),
    ) {
      $0.repositoryCustomization = nil
    }
  }
}
