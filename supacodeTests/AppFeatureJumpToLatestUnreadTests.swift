import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
@Suite(.serialized)
struct AppFeatureJumpToLatestUnreadTests {
  @Test(.dependencies) func noOpWhenNoUnreadNotifications() async {
    let worktree = makeWorktree()
    let focused = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.latestUnreadNotification = { nil }
      $0.terminalClient.send = { command in
        focused.withValue { $0.append(command) }
      }
    }

    await store.send(.jumpToLatestUnread)
    await store.finish()

    #expect(focused.value.isEmpty)
  }

  @Test(.dependencies) func selectsWorktreeAndFocusesSurfaceOnJump() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let notificationUUID = UUID()
    let focused = LockIsolated<[TerminalClient.Command]>([])
    let marked = LockIsolated<[(Worktree.ID, UUID)]>([])
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.latestUnreadNotification = {
        NotificationLocation(
          worktreeID: worktree.id,
          tabID: TerminalTabID(rawValue: tabUUID),
          surfaceID: surfaceUUID,
          notificationID: notificationUUID,
        )
      }
      $0.terminalClient.send = { command in
        focused.withValue { $0.append(command) }
      }
      $0.terminalClient.markNotificationRead = { worktreeID, notificationID in
        marked.withValue { $0.append((worktreeID, notificationID)) }
      }
    }

    await store.send(.jumpToLatestUnread)
    await store.receive(\.repositories.selectWorktree)
    await store.finish()

    let expectedFocus = TerminalClient.Command.focusSurface(
      worktree,
      tabID: TerminalTabID(rawValue: tabUUID),
      surfaceID: surfaceUUID,
      input: nil
    )
    // Only the focus command should flow through `send`; the side-effect
    // setSelectedWorktreeID is produced by the `selectWorktree` delegate
    // and is tested separately. Using an exact-length assertion prevents
    // a future refactor from quietly duplicating the focus command.
    let focusCommands = focused.value.filter {
      if case .focusSurface = $0 { return true } else { return false }
    }
    #expect(focusCommands == [expectedFocus])

    #expect(marked.value.count == 1)
    #expect(marked.value.first?.0 == worktree.id)
    #expect(marked.value.first?.1 == notificationUUID)
  }

  @Test(.dependencies) func dropsJumpWhenTargetWorktreeMissing() async {
    let worktree = makeWorktree()
    let missingID = "/tmp/repo/does-not-exist"
    let focused = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.latestUnreadNotification = {
        NotificationLocation(
          worktreeID: missingID,
          tabID: TerminalTabID(rawValue: UUID()),
          surfaceID: UUID(),
          notificationID: UUID(),
        )
      }
      $0.terminalClient.send = { command in
        focused.withValue { $0.append(command) }
      }
    }

    await store.send(.jumpToLatestUnread)
    await store.finish()

    #expect(focused.value.isEmpty)
  }

  // MARK: - Helpers.

  private func makeWorktree(
    id: String = "/tmp/repo/wt-1",
    name: String = "wt-1"
  ) -> Worktree {
    Worktree(
      id: id,
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
