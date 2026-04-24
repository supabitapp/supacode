import ComposableArchitecture
import Foundation
import IdentifiedCollections
import OrderedCollections
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
