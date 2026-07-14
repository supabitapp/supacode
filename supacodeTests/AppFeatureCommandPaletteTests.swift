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
    let surfaceID = UUID()
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
      $0.terminalClient.selectedSurfaceID = { _ in surfaceID }
    }

    await store.send(.commandPalette(.delegate(.ghosttyCommand("goto_split:right"))))
    await store.finish()

    #expect(
      sent.value == [
        .performBindingActionOnSurface(worktree, surfaceID: surfaceID, action: "goto_split:right")
      ]
    )
  }

  @Test(.dependencies) func ghosttyCommandFallsBackWhenNoSelectedSurface() async {
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
      $0.terminalClient.selectedSurfaceID = { _ in nil }
    }

    await store.send(.commandPalette(.delegate(.ghosttyCommand("goto_split:right"))))
    await store.finish()

    #expect(sent.value == [.performBindingAction(worktree, action: "goto_split:right")])
  }

  @Test(.dependencies) func ghosttyCommandCapturesSelectedSurfaceBeforeAsyncDispatch() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-ghostty/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-ghostty"
    )
    let repository = makeRepository(id: "/tmp/repo-ghostty", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let firstSurface = UUID()
    let secondSurface = UUID()
    let currentSurface = LockIsolated(firstSurface)
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
      $0.terminalClient.selectedSurfaceID = { _ in currentSurface.value }
    }

    let task = await store.send(.commandPalette(.delegate(.ghosttyCommand("toggle_split_zoom"))))
    // Simulates the palette-dismiss focus drift: by the time the async dispatch
    // resolves, `selectedSurfaceID` would already point at the leftmost surface.
    currentSurface.setValue(secondSurface)
    await task.finish()

    #expect(
      sent.value == [
        .performBindingActionOnSurface(worktree, surfaceID: firstSurface, action: "toggle_split_zoom")
      ]
    )
  }

  @Test(.dependencies) func promptSurfaceTitleGhosttyCommandCapturesSelectedTabIDSynchronously() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-ghostty/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-ghostty"
    )
    let repository = makeRepository(id: "/tmp/repo-ghostty", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let capturedTabID = TerminalTabID()
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
      $0.terminalClient.selectedTabID = { _ in capturedTabID }
    }

    await store.send(.commandPalette(.delegate(.ghosttyCommand("prompt_surface_title"))))
    await store.finish()

    #expect(sent.value == [.beginTabRename(worktree, tabID: capturedTabID)])
  }

  @Test(.dependencies) func promptTabTitleGhosttyCommandCapturesSelectedTabIDSynchronously() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-ghostty/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-ghostty"
    )
    let repository = makeRepository(id: "/tmp/repo-ghostty", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let capturedTabID = TerminalTabID()
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
      $0.terminalClient.selectedTabID = { _ in capturedTabID }
    }

    await store.send(.commandPalette(.delegate(.ghosttyCommand("prompt_tab_title"))))
    await store.finish()

    #expect(sent.value == [.beginTabRename(worktree, tabID: capturedTabID)])
  }

  @Test(.dependencies) func promptTitleGhosttyCommandCapturesSelectedTabIDBeforeAsyncDispatch() async {
    let worktree = makeWorktree(
      id: "/tmp/repo-ghostty/wt-1",
      name: "wt-1",
      repoRoot: "/tmp/repo-ghostty"
    )
    let repository = makeRepository(id: "/tmp/repo-ghostty", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    let firstTabID = TerminalTabID()
    let secondTabID = TerminalTabID()
    let currentTabID = LockIsolated(firstTabID)
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
      $0.terminalClient.selectedTabID = { _ in currentTabID.value }
    }

    let task = await store.send(.commandPalette(.delegate(.ghosttyCommand("prompt_surface_title"))))
    // Mutate the source AFTER dispatch but before the async effect resolves.
    // Synchronous capture means the originally-focused tab ID is locked into the command.
    currentTabID.setValue(secondTabID)
    await task.finish()

    #expect(sent.value == [.beginTabRename(worktree, tabID: firstTabID)])
  }

  @Test(.dependencies) func promptTitleGhosttyCommandPassesNilTabIDWhenNoneSelected() async {
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
      $0.terminalClient.selectedTabID = { _ in nil }
    }

    await store.send(.commandPalette(.delegate(.ghosttyCommand("prompt_surface_title"))))
    await store.finish()

    #expect(sent.value == [.beginTabRename(worktree, tabID: nil)])
  }

  @Test(.dependencies) func nonPromptTitleGhosttyCommandFallsThroughToBindingAction() async {
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
      $0.terminalClient.selectedSurfaceID = { _ in nil }
    }

    await store.send(.commandPalette(.delegate(.ghosttyCommand("new_split:right"))))
    await store.finish()

    #expect(sent.value == [.performBindingAction(worktree, action: "new_split:right")])
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
      TextState("Delete worktree?")
    } actions: {
      ButtonState(
        role: .destructive,
        action: .confirmDeleteSidebarItems([target], disposition: .gitWorktreeDelete)
      ) {
        TextState("Delete worktree")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("This deletes the worktree directory and its local branch.")
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
        TextState("Archive worktree")
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

  @Test(.dependencies) func renameBranchDispatchesRequest() async {
    let mainWorktree = makeWorktree(
      id: "/tmp/repo-rename/main",
      name: "main",
      repoRoot: "/tmp/repo-rename"
    )
    let worktree = makeWorktree(
      id: "/tmp/repo-rename/wt-1",
      name: "feature/old",
      repoRoot: "/tmp/repo-rename"
    )
    let repository = makeRepository(
      id: "/tmp/repo-rename",
      worktrees: [mainWorktree, worktree]
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.repositoryRoots = [repository.rootURL]
    repositoriesState.reconcileSidebarForTesting()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.commandPalette(.delegate(.renameBranch(worktree.id, repository.id))))
    await store.receive(\.repositories.requestRenameBranch) {
      $0.repositories.renameBranchPrompt = RenameBranchFeature.State(
        worktreeID: worktree.id,
        repositoryID: repository.id,
        repositoryRootURL: repository.rootURL,
        host: nil,
        currentName: "feature/old"
      )
    }
  }

  @Test(.dependencies) func customizeRepositoryAppearanceDispatchesRequest() async {
    let mainWorktree = makeWorktree(
      id: "/tmp/repo-appearance",
      name: "main",
      repoRoot: "/tmp/repo-appearance"
    )
    let repository = makeRepository(id: "/tmp/repo-appearance", worktrees: [mainWorktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.repositoryRoots = [repository.rootURL]
    repositoriesState.reconcileSidebarForTesting()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.commandPalette(.delegate(.customizeRepositoryAppearance(repository.id))))
    await store.receive(\.repositories.requestCustomizeRepository) {
      $0.repositories.repositoryCustomization = RepositoryCustomizationFeature.State(
        repositoryID: repository.id,
        defaultName: "repo",
        title: "",
        color: nil
      )
    }
  }

  @Test(.dependencies) func customizeWorktreeAppearanceDispatchesRequest() async {
    let mainWorktree = makeWorktree(
      id: "/tmp/repo-appearance-wt",
      name: "main",
      repoRoot: "/tmp/repo-appearance-wt"
    )
    let worktree = makeWorktree(
      id: "/tmp/repo-appearance-wt/wt-1",
      name: "feature/old",
      repoRoot: "/tmp/repo-appearance-wt"
    )
    let repository = makeRepository(
      id: "/tmp/repo-appearance-wt",
      worktrees: [mainWorktree, worktree]
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.repositoryRoots = [repository.rootURL]
    repositoriesState.reconcileSidebarForTesting()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.commandPalette(.delegate(.customizeWorktreeAppearance(worktree.id, repository.id))))
    await store.receive(\.repositories.requestCustomizeWorktree) {
      $0.repositories.worktreeCustomization = WorktreeCustomizationFeature.State(
        worktreeID: worktree.id,
        repositoryID: repository.id,
        defaultName: "feature/old",
        title: "",
        color: nil
      )
    }
  }

  @Test(.dependencies) func selectWorktreeDelegateSelectsAndFocusesTerminal() async {
    let worktree = makeWorktree(id: "/tmp/repo-goto/wt-1", name: "wt-1", repoRoot: "/tmp/repo-goto")
    let repository = makeRepository(id: "/tmp/repo-goto", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.repositoryRoots = [repository.rootURL]
    repositoriesState.reconcileSidebarForTesting()
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: SettingsFeature.State())
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    // Palette completion selects the worktree AND focuses its terminal
    // (`focusTerminal: true`), so the selection change requests terminal focus.
    await store.send(.commandPalette(.delegate(.selectWorktree(worktree.id))))
    await store.receive(\.repositories.selectWorktree)
    await store.receive(\.repositories.sidebarItems)
  }

  @Test(.dependencies) func dismissedWithoutSelectionRefocusesCurrentTerminal() async {
    let worktree = makeWorktree(id: "/tmp/repo-dismiss/wt-1", name: "wt-1", repoRoot: "/tmp/repo-dismiss")
    let repository = makeRepository(id: "/tmp/repo-dismiss", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.repositoryRoots = [repository.rootURL]
    repositoriesState.reconcileSidebarForTesting()
    repositoriesState.selection = .worktree(worktree.id)
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: SettingsFeature.State())
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    // Cancelling the palette refocuses the current worktree's terminal.
    await store.send(.commandPalette(.delegate(.dismissedWithoutSelection)))
    await store.receive(\.repositories.sidebarItems)
  }

  @Test(.dependencies) func dismissedWithoutSelectionNoOpsWithoutSelection() async {
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    // No selected worktree: there is no terminal to refocus, so this is a no-op.
    await store.send(.commandPalette(.delegate(.dismissedWithoutSelection)))
  }

  @Test(.dependencies) func dismissedWithoutSelectionNoOpsWhenSelectionMissingFromSidebar() async {
    var repositoriesState = RepositoriesFeature.State()
    // Selection points at a worktree that never made it into `sidebarItems`
    // (e.g. just deleted); the guard's second branch must still no-op.
    repositoriesState.selection = .worktree(WorktreeID("/tmp/ghost/wt"))
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState, settings: SettingsFeature.State())
    ) {
      AppFeature()
    }

    await store.send(.commandPalette(.delegate(.dismissedWithoutSelection)))
  }

  @Test(.dependencies) func terminalToggleAlwaysOpensCommandsMode() async {
    let worktree = makeWorktree(id: "/tmp/repo-toggle/wt", name: "wt", repoRoot: "/tmp/repo-toggle")
    let repository = makeRepository(id: "/tmp/repo-toggle", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.repositoryRoots = [repository.rootURL]
    repositoriesState.reconcileSidebarForTesting()
    var appState = AppFeature.State(repositories: repositoriesState, settings: SettingsFeature.State())
    // The palette was last used as the worktree switcher and is now closed.
    appState.commandPalette.mode = .worktreeSwitcher
    let store = TestStore(initialState: appState) {
      AppFeature()
    }
    store.exhaustivity = .off

    // Ghostty's toggle opens the command palette, never the last-used switcher.
    await store.send(.terminalEvent(.commandPaletteToggleRequested(worktreeID: worktree.id)))
    await store.receive(\.commandPalette.togglePresentInMode)
    #expect(store.state.commandPalette.mode == .commands)
    #expect(store.state.commandPalette.isPresented == true)
  }

  @Test(.dependencies) func terminalToggleSwitchesOpenWorktreeSwitcherToCommands() async {
    let worktree = makeWorktree(id: "/tmp/repo-toggle/wt", name: "wt", repoRoot: "/tmp/repo-toggle")
    let repository = makeRepository(id: "/tmp/repo-toggle", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.repositoryRoots = [repository.rootURL]
    repositoriesState.reconcileSidebarForTesting()
    var appState = AppFeature.State(repositories: repositoriesState, settings: SettingsFeature.State())
    // The worktree switcher is already open.
    appState.commandPalette.isPresented = true
    appState.commandPalette.mode = .worktreeSwitcher
    let store = TestStore(initialState: appState) {
      AppFeature()
    }
    store.exhaustivity = .off

    // The switcher swaps to the command palette rather than closing.
    await store.send(.terminalEvent(.commandPaletteToggleRequested(worktreeID: worktree.id)))
    await store.receive(\.commandPalette.togglePresentInMode)
    #expect(store.state.commandPalette.mode == .commands)
    #expect(store.state.commandPalette.isPresented == true)
  }

  @Test(.dependencies) func terminalToggleClosingTheCommandPaletteDoesNotChangeSelection() async {
    let selected = makeWorktree(id: "/tmp/repo-close/wt-a", name: "wt-a", repoRoot: "/tmp/repo-close")
    let origin = makeWorktree(id: "/tmp/repo-close/wt-b", name: "wt-b", repoRoot: "/tmp/repo-close")
    let repository = makeRepository(id: "/tmp/repo-close", worktrees: [selected, origin])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.repositoryRoots = [repository.rootURL]
    repositoriesState.reconcileSidebarForTesting()
    repositoriesState.setSingleWorktreeSelection(selected.id)
    var appState = AppFeature.State(repositories: repositoriesState, settings: SettingsFeature.State())
    appState.commandPalette.isPresented = true
    appState.commandPalette.mode = .commands
    let store = TestStore(initialState: appState) {
      AppFeature()
    }
    store.exhaustivity = .off

    // The toggle fires from wt-b's surface while wt-a is selected. Closing must not
    // drag the selection onto the originating worktree.
    await store.send(.terminalEvent(.commandPaletteToggleRequested(worktreeID: origin.id)))
    await store.receive(\.commandPalette.togglePresentInMode)
    await store.receive(\.commandPalette.setPresented)
    await store.receive(\.commandPalette.delegate.dismissedWithoutSelection)
    #expect(store.state.commandPalette.isPresented == false)
    #expect(store.state.repositories.selectedWorktreeID == selected.id)
  }

}

private func makeWorktree(id: String, name: String, repoRoot: String = "/tmp/repo") -> Worktree {
  Worktree(
    id: WorktreeID(id),
    name: name,
    detail: "detail",
    workingDirectory: URL(fileURLWithPath: id),
    repositoryRootURL: URL(fileURLWithPath: repoRoot)
  )
}

private func makeRepository(id: String, worktrees: [Worktree]) -> Repository {
  Repository(
    id: RepositoryID(id),
    rootURL: URL(fileURLWithPath: id),
    name: "repo",
    worktrees: IdentifiedArray(uniqueElements: worktrees)
  )
}
