import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureMenuBarNotificationsTests {
  @Test(.dependencies) func menuBarNotificationSelectedFocusesSurfaceAndMarksRead() async {
    let worktree = makeWorktree()
    let tabID = TerminalTabID()
    let surfaceID = UUID()
    let notificationID = UUID()
    let focused = LockIsolated<[TerminalClient.Command]>([])
    let marked = LockIsolated<[(Worktree.ID, UUID)]>([])
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.send = { command in
        focused.withValue { $0.append(command) }
      }
      $0.terminalClient.markNotificationRead = { worktreeID, notificationID in
        marked.withValue { $0.append((worktreeID, notificationID)) }
      }
    }

    await store.send(
      .menuBarNotificationSelected(
        worktreeID: worktree.id, tabID: tabID, surfaceID: surfaceID, notificationID: notificationID
      )
    )
    await store.receive(\.repositories.selectWorktree)
    await store.finish()

    let focusCommands = focused.value.filter {
      if case .focusSurface = $0 { return true } else { return false }
    }
    #expect(
      focusCommands == [.focusSurface(worktree, tabID: tabID, surfaceID: surfaceID, input: nil)]
    )
    #expect(marked.value.count == 1)
    #expect(marked.value.first?.0 == worktree.id)
    #expect(marked.value.first?.1 == notificationID)
  }

  @Test(.dependencies) func menuBarNotificationSelectedResolvesTabWhenMissing() async {
    let worktree = makeWorktree()
    let resolvedTabID = TerminalTabID()
    let surfaceID = UUID()
    let focused = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.tabID = { _, _ in resolvedTabID }
      $0.terminalClient.send = { command in
        focused.withValue { $0.append(command) }
      }
      $0.terminalClient.markNotificationRead = { _, _ in }
    }

    await store.send(
      .menuBarNotificationSelected(
        worktreeID: worktree.id, tabID: nil, surfaceID: surfaceID, notificationID: UUID()
      )
    )
    await store.finish()

    let focusCommands = focused.value.filter {
      if case .focusSurface = $0 { return true } else { return false }
    }
    #expect(
      focusCommands == [.focusSurface(worktree, tabID: resolvedTabID, surfaceID: surfaceID, input: nil)]
    )
  }

  @Test(.dependencies) func menuBarNotificationSelectedStillMarksReadWhenSurfaceGone() async {
    let worktree = makeWorktree()
    let focused = LockIsolated<[TerminalClient.Command]>([])
    let marked = LockIsolated<[(Worktree.ID, UUID)]>([])
    let notificationID = UUID()
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.tabID = { _, _ in nil }
      $0.terminalClient.send = { command in
        focused.withValue { $0.append(command) }
      }
      $0.terminalClient.markNotificationRead = { worktreeID, notificationID in
        marked.withValue { $0.append((worktreeID, notificationID)) }
      }
    }

    await store.send(
      .menuBarNotificationSelected(
        worktreeID: worktree.id, tabID: nil, surfaceID: UUID(), notificationID: notificationID
      )
    )
    await store.finish()

    let focusCommands = focused.value.filter {
      if case .focusSurface = $0 { return true } else { return false }
    }
    #expect(focusCommands.isEmpty)
    #expect(marked.value.count == 1)
    #expect(marked.value.first?.1 == notificationID)
  }

  @Test(.dependencies) func menuBarWorktreeSelectedSelectsWorktree() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree) { _ in }

    await store.send(.menuBarWorktreeSelected(worktreeID: worktree.id))
    await store.receive(\.repositories.selectWorktree)
    await store.finish()

    #expect(store.state.repositories.selectedWorktreeID == worktree.id)
  }

  @Test(.dependencies) func markAllNotificationsReadForwardsToTerminalClient() async {
    let worktree = makeWorktree()
    let calls = LockIsolated(0)
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.markAllNotificationsRead = {
        calls.withValue { $0 += 1 }
      }
    }

    await store.send(.markAllNotificationsRead)
    await store.finish()

    #expect(calls.value == 1)
  }

  @Test(.dependencies) func showNotificationsPanePresentsNotificationsInspector() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree) { _ in }

    await store.send(.showNotificationsPane)
    await store.receive(\.repositories.toggleInspectorPane)
    await store.finish()

    #expect(store.state.repositories.inspectorPresented)
    #expect(store.state.repositories.inspectorPane == .notifications)
  }

  @Test(.dependencies) func showNotificationsPaneDoesNotToggleAwayWhenAlreadyPresented() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree) { _ in }

    await store.send(.showNotificationsPane)
    await store.receive(\.repositories.toggleInspectorPane)
    // A second invocation must keep the pane open instead of toggling it closed.
    await store.send(.showNotificationsPane)
    await store.finish()

    #expect(store.state.repositories.inspectorPresented)
    #expect(store.state.repositories.inspectorPane == .notifications)
  }

  // MARK: - Helpers.

  private func makeWorktree(
    id: String = "/tmp/repo/wt-1",
    name: String = "wt-1"
  ) -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
  }

  private func makeStore(
    worktree: Worktree,
    withAdditionalDependencies: (inout DependencyValues) -> Void
  ) -> TestStoreOf<AppFeature> {
    var repositoriesState = RepositoriesFeature.State()
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: [worktree],
    )
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    repositoriesState.isInitialLoadComplete = true

    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: { values in
      values.terminalClient.tabExists = { _, _ in true }
      values.terminalClient.surfaceExists = { _, _, _ in true }
      withAdditionalDependencies(&values)
    }
    store.exhaustivity = .off
    return store
  }
}
