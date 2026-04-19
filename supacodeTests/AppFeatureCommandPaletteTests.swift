import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureCommandPaletteTests {
  @Test(.dependencies) func openSettingsSetsSelection() async {
    var state = AppFeature.State()
    state.settings.selection = .updates
    let store = TestStore(initialState: state) {
      AppFeature()
    }

    await store.send(.commandPalette(.delegate(.openSettings)))
    await store.receive(\.settings.setSelection) {
      $0.settings.selection = .general
    }
  }

  @Test(.dependencies) func newWorktreeDispatchesCreateRandomWorktree() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Open a repository to create a worktree.")
    }

    await store.send(.commandPalette(.delegate(.newWorktree)))
    await store.receive(\.repositories.createRandomWorktree) {
      $0.repositories.alert = expectedAlert
    }
  }

  @Test(.dependencies) func openRepositoryShowsOpenPanel() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.commandPalette(.delegate(.openRepository)))
    await store.receive(\.repositories.setOpenPanelPresented) {
      $0.repositories.isOpenPanelPresented = true
    }
  }

  @Test(.dependencies) func refreshWorktreesDispatchesRefresh() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.refreshWorktrees)))
    await store.receive(\.repositories.refreshWorktrees)
  }

  @Test(.dependencies) func viewArchivedWorktreesDispatchesSelectArchived() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.viewArchivedWorktrees)))
    await store.receive(\.repositories.selectArchivedWorktrees) {
      $0.repositories.selection = .archivedWorktrees
      $0.repositories.sidebarSelectedWorktreeIDs = []
    }
  }

  @Test(.dependencies) func checkForUpdatesDispatchesUpdateAction() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.commandPalette(.delegate(.checkForUpdates)))
    await store.receive(\.updates.checkForUpdates)
  }

  @Test(.dependencies) func ghosttyCommandDispatchesBindingActionToTerminalClient() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-ghostty/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-ghostty"
    )
    let repository = makeRepository(id: "/tmp/repo-ghostty", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.commandPalette(.delegate(.ghosttyCommand("goto_split:right"))))
    await store.finish()

    #expect(
      sent.value == [
        .performBindingAction(worktree, action: "goto_split:right")
      ]
    )
  }

  @Test(.dependencies) func closePullRequestDispatchesAction() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.closePullRequest("/tmp/repo/wt-close"))))
    await store.receive(\.repositories.pullRequestAction)
  }

  @Test(.dependencies) func removeWorktreeDispatchesRequest() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-run/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-run"
    )
    let repository = makeRepository(id: "/tmp/repo-run", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    let target = RepositoriesFeature.DeleteWorktreeTarget(
      worktreeID: worktree.id, repositoryID: repository.id)
    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("🚨 Delete worktree?")
    } actions: {
      ButtonState(
        role: .destructive,
        action: .confirmDeleteSidebarItems([target], disposition: .gitWorktreeDelete)
      ) {
        TextState("Delete (⌘↩)")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("Delete \(worktree.name)? This deletes the worktree directory and its local branch.")
    }

    await store.send(.commandPalette(.delegate(.removeWorktree(worktree.id, repository.id))))
    await store.receive(\.repositories.requestDeleteSidebarItems) {
      $0.repositories.alert = expectedAlert
    }
  }

  @Test(.dependencies) func archiveWorktreeDispatchesRequest() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-archive/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-archive"
    )
    let repository = makeRepository(id: "/tmp/repo-archive", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    let archivedDisplay = AppShortcuts.archivedWorktrees.display
    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Archive worktree?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmArchiveWorktree(worktree.id, repository.id)) {
        TextState("Archive (⌘↩)")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState(
        "You can find \(worktree.name) later in Menu Bar > Worktrees > Archived Worktrees (\(archivedDisplay))."
      )
    }

    await store.send(.commandPalette(.delegate(.archiveWorktree(worktree.id, repository.id))))
    await store.receive(\.repositories.requestArchiveWorktree) {
      $0.repositories.alert = expectedAlert
    }
  }

}

private func makeWorktree(id: String, name: String, repoRoot: String = "/tmp/repo") -> Worktree {
  Worktree(
    id: id,
    name: name,
    detail: "detail",
    workingDirectory: URL(fileURLWithPath: id),
    repositoryRootURL: URL(fileURLWithPath: repoRoot)
  )
}

private func makeRepository(id: String, worktrees: [Worktree]) -> Repository {
  Repository(
    id: id,
    rootURL: URL(fileURLWithPath: id),
    name: "repo",
    worktrees: IdentifiedArray(uniqueElements: worktrees)
  )
}
