import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import SupacodeSettingsShared
import Testing

@testable import SupacodeSettingsFeature
@testable import supacode

@MainActor
struct AppFeatureSplitTerminalTests {
  @Test(
    arguments: [
      (TerminalSplitMenuDirection.right, SplitTree<PaneID>.NewDirection.right),
      (.left, .left),
      (.down, .down),
      // The split tree names the upward insertion `top`.
      (.up, .top),
    ]
  )
  func newSplitDirectionMapsLiterally(direction: TerminalSplitMenuDirection, expected: SplitTree<PaneID>.NewDirection) {
    #expect(direction.newSplitDirection == expected)
  }

  @Test(
    arguments: [
      (TerminalSplitMenuDirection.right, SplitTree<PaneID>.FocusDirection.spatial(.right)),
      (.left, .spatial(.left)),
      (.down, .spatial(.down)),
      (.up, .spatial(.top)),
    ]
  )
  func focusSplitDirectionMapsLiterally(
    direction: TerminalSplitMenuDirection,
    expected: SplitTree<PaneID>.FocusDirection
  ) {
    #expect(direction.focusSplitDirection == expected)
  }

  @Test(
    arguments: [
      (TerminalSplitMenuDirection.right, AppShortcutID.splitRight, AppShortcutID.focusSplitRight),
      (.left, .splitLeft, .focusSplitLeft),
      (.down, .splitDown, .focusSplitDown),
      (.up, .splitUp, .focusSplitUp),
    ]
  )
  func directionMapsToItsLayoutShortcuts(
    direction: TerminalSplitMenuDirection,
    split: AppShortcutID,
    focus: AppShortcutID
  ) {
    #expect(direction.appShortcut.id == split)
    #expect(direction.focusAppShortcut.id == focus)
  }

  @Test(.dependencies, arguments: TerminalSplitMenuDirection.allCases)
  func splitTerminalForwardsTheLayoutCommand(direction: TerminalSplitMenuDirection) async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.splitTerminal(direction))
    await store.finish()
    #expect(sent.value == [.splitFocusedPane(worktree, direction: direction)])
  }

  @Test(.dependencies) func splitTerminalWithoutSelectionIsNoop() async {
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in
        Issue.record("terminalClient.send should not be called without a selected worktree")
      }
    }

    await store.send(.splitTerminal(.right))
    await store.finish()
  }

  @Test(.dependencies, arguments: TerminalSplitMenuDirection.allCases)
  func focusSplitForwardsTheLayoutCommand(direction: TerminalSplitMenuDirection) async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.focusSplit(direction))
    await store.finish()
    #expect(sent.value == [.focusSplit(worktree, direction: direction)])
  }

  @Test(.dependencies) func toggleSplitZoomForwardsTheLayoutCommand() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.toggleSplitZoom)
    await store.finish()
    #expect(sent.value == [.toggleSplitZoom(worktree)])
  }

  @Test(.dependencies) func equalizeSplitsForwardsTheLayoutCommand() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.equalizeSplits)
    await store.finish()
    #expect(sent.value == [.equalizeSplits(worktree)])
  }

  @Test(.dependencies) func toggleWindowModeForwardsToTheTerminalClient() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.toggleWindowModeForFocusedPane)
    await store.finish()
    #expect(sent.value == [.toggleWindowModeForFocusedPane(worktree)])
  }

  @Test(.dependencies) func toggleWindowModeWithoutSelectionIsNoop() async {
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in
        Issue.record("terminalClient.send should not be called without a selected worktree")
      }
    }

    await store.send(.toggleWindowModeForFocusedPane)
    await store.finish()
  }

  @Test(.dependencies) func focusSplitWithoutSelectionIsNoop() async {
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in
        Issue.record("terminalClient.send should not be called without a selected worktree")
      }
    }

    await store.send(.focusSplit(.left))
    await store.finish()
  }

  @Test(.dependencies) func toggleSplitZoomWithoutSelectionIsNoop() async {
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in
        Issue.record("terminalClient.send should not be called without a selected worktree")
      }
    }

    await store.send(.toggleSplitZoom)
    await store.finish()
  }

  @Test(.dependencies) func equalizeSplitsWithoutSelectionIsNoop() async {
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in
        Issue.record("terminalClient.send should not be called without a selected worktree")
      }
    }

    await store.send(.equalizeSplits)
    await store.finish()
  }

  private func makeWorktree() -> Worktree {
    Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func makeRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: [worktree]
    )
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    state.selection = .worktree(worktree.id)
    return state
  }
}
