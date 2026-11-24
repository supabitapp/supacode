import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import SupacodeSettingsShared
import Testing

@testable import SupacodeSettingsFeature
@testable import supacode

@MainActor
struct AppFeatureMissingWorktreeTerminalTests {
  private let worktree = Worktree(
    id: "/tmp/repo/missing",
    name: "missing",
    detail: "missing",
    workingDirectory: URL(fileURLWithPath: "/tmp/repo/missing"),
    repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    isMissing: true
  )

  @Test func openTabsKeepTheTerminalAreaUntilTheLastOneCloses() {
    let paneID = PaneID()
    let tab = TabItem(
      id: TabID(),
      title: "agent",
      content: ContentSnapshot(id: ContentID(), state: .terminal(TerminalContentState(workingDirectory: nil)))
    )
    let populated = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [Pane(id: paneID, tabs: [tab], selectedTabID: tab.id)],
      focusedPaneID: paneID
    )
    let healthy = Worktree(
      id: "/tmp/repo/healthy",
      name: "healthy",
      detail: "healthy",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/healthy"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )

    #expect(WorktreeDetailView.TerminalAccess(worktree: worktree, layout: populated) == .existingTabsOnly)
    #expect(WorktreeDetailView.TerminalAccess(worktree: worktree, layout: PaneLayout()) == .hidden)
    #expect(WorktreeDetailView.TerminalAccess(worktree: worktree, layout: nil) == .hidden)
    #expect(WorktreeDetailView.TerminalAccess(worktree: healthy, layout: nil) == .full)
  }

  @Test(.dependencies) func newShellsAreRefused() async {
    let (store, sent) = makeStore()

    await store.send(.newTerminal)
    await store.send(.newTerminalInWorktree(worktree.id))
    await store.send(.splitTerminal(.right))
    await store.finish()

    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func selectingItBootstrapsNoShell() async {
    let (store, sent) = makeStore()
    let storage = SettingsTestStorage()
    store.dependencies.worktreeInfoWatcher.send = { _ in }
    store.dependencies.settingsFileStorage = storage.storage
    store.dependencies.settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree))))
    await store.finish()

    #expect(sent.value == [.setSelectedWorktreeID(worktree.id)])
  }

  @Test(.dependencies) func openTabsStayReachable() async {
    let (store, sent) = makeStore()

    await store.send(.selectTerminalTabAtIndex(2))
    await store.send(.selectNextTerminalTab)
    await store.send(.selectPreviousTerminalTab)
    await store.send(.focusSplit(.left))
    await store.send(.toggleSplitZoom)
    await store.send(.equalizeSplits)
    await store.send(.toggleWindowModeForFocusedPane)
    await store.finish()

    #expect(
      sent.value == [
        .selectTabAtIndex(worktree, index: 2),
        .selectRelativeTab(worktree, forward: true),
        .selectRelativeTab(worktree, forward: false),
        .focusSplit(worktree, direction: .left),
        .toggleSplitZoom(worktree),
        .equalizeSplits(worktree),
        .toggleWindowModeForFocusedPane(worktree),
      ]
    )
  }

  private func makeStore() -> (TestStoreOf<AppFeature>, LockIsolated<[TerminalClient.Command]>) {
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [
      Repository(
        id: "/tmp/repo",
        rootURL: URL(fileURLWithPath: "/tmp/repo"),
        name: "repo",
        worktrees: [worktree]
      )
    ]
    repositories.selection = .worktree(worktree.id)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off
    return (store, sent)
  }
}
