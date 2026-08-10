import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsFeature
@testable import supacode

@MainActor
struct AppFeatureRenameTabTests {
  @Test(.dependencies) func selectedTabBeginsRename() async {
    let worktree = Self.makeWorktree(id: "/tmp/rename-tab/wt-1")
    let store = Self.makeStore(worktrees: [worktree], selection: worktree.id)
    let tabID = TabID()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    store.dependencies.terminalClient.selectedTabID = { _ in tabID }
    store.dependencies.terminalClient.send = { command in
      sent.withValue { $0.append(command) }
    }

    await store.send(.renameSelectedTerminalTab).finish()

    #expect(sent.value == [.beginTabRename(worktree, tabID: tabID)])
  }

  @Test(.dependencies) func noSelectedWorktreeDoesNothing() async {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = Self.makeStore(worktrees: [], selection: nil)
    store.dependencies.terminalClient.send = { command in
      sent.withValue { $0.append(command) }
    }

    await store.send(.renameSelectedTerminalTab).finish()

    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func missingSelectedWorktreeDoesNothing() async {
    let worktree = Self.makeWorktree(id: "/tmp/rename-tab/missing", isMissing: true)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = Self.makeStore(worktrees: [worktree], selection: worktree.id)
    store.dependencies.terminalClient.send = { command in
      sent.withValue { $0.append(command) }
    }

    await store.send(.renameSelectedTerminalTab).finish()

    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func noSelectedTabDoesNothing() async {
    let worktree = Self.makeWorktree(id: "/tmp/rename-tab/wt-1")
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = Self.makeStore(worktrees: [worktree], selection: worktree.id)
    store.dependencies.terminalClient.selectedTabID = { _ in nil }
    store.dependencies.terminalClient.send = { command in
      sent.withValue { $0.append(command) }
    }

    await store.send(.renameSelectedTerminalTab).finish()

    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func selectedTabIsCapturedBeforeAsyncDispatch() async {
    let worktree = Self.makeWorktree(id: "/tmp/rename-tab/wt-1")
    let firstTabID = TabID()
    let secondTabID = TabID()
    let currentTabID = LockIsolated(firstTabID)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = Self.makeStore(worktrees: [worktree], selection: worktree.id)
    store.dependencies.terminalClient.selectedTabID = { _ in currentTabID.value }
    store.dependencies.terminalClient.send = { command in
      sent.withValue { $0.append(command) }
    }

    let task = await store.send(.renameSelectedTerminalTab)
    currentTabID.setValue(secondTabID)
    await task.finish()

    #expect(sent.value == [.beginTabRename(worktree, tabID: firstTabID)])
  }

  private static func makeStore(
    worktrees: IdentifiedArrayOf<Worktree>,
    selection: Worktree.ID?
  ) -> TestStoreOf<AppFeature> {
    var repositories = RepositoriesFeature.State()
    if !worktrees.isEmpty {
      repositories.repositories = [
        Repository(
          id: RepositoryID("/tmp/rename-tab"),
          rootURL: URL(fileURLWithPath: "/tmp/rename-tab"),
          name: "rename-tab",
          worktrees: worktrees
        )
      ]
    }
    if let selection {
      repositories.selection = .worktree(selection)
    }
    return TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }
  }

  private static func makeWorktree(id: String, isMissing: Bool = false) -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/rename-tab"),
      isMissing: isMissing
    )
  }
}
