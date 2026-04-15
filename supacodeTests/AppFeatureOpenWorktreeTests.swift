import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureOpenWorktreeTests {
  @Test(.dependencies) func revealInFinderOpensFinderAction() async {
    let (store, context) = makeStore()

    await store.send(.revealInFinder)
    #expect(context.openedActions.value == [.finder])
    #expect(context.capturedEvents.value == [CapturedEvent(name: "worktree_opened", source: "revealInFinder")])
    await store.finish()
  }

  @Test(.dependencies) func contextMenuOpenWorktreeDelegatesToAppFeature() async {
    let (store, context) = makeStore()

    await store.send(.repositories(.contextMenuOpenWorktree(context.worktree.id, .terminal)))
    await store.receive(\.repositories.delegate.openWorktreeInApp)
    #expect(context.openedActions.value == [.terminal])
    #expect(context.capturedEvents.value == [CapturedEvent(name: "worktree_opened", source: "contextMenu")])
    await store.finish()
  }

  @Test(.dependencies) func contextMenuEditorActionCreatesTerminalTab() async {
    let (store, context) = makeStore()

    await store.send(.repositories(.contextMenuOpenWorktree(context.worktree.id, .editor)))
    await store.receive(\.repositories.delegate.openWorktreeInApp)
    #expect(context.openedActions.value.isEmpty)
    #expect(
      context.terminalCommands.value == [
        .createTabWithInput(context.worktree, input: "$EDITOR", runSetupScriptIfNew: false)
      ]
    )
    await store.finish()
  }

  @Test(.dependencies) func contextMenuEditorActionRunsSetupScriptWhenPending() async {
    let (store, context) = makeStore { $0.pendingSetupScriptWorktreeIDs = [$1.id] }

    await store.send(.repositories(.contextMenuOpenWorktree(context.worktree.id, .editor)))
    await store.receive(\.repositories.delegate.openWorktreeInApp)
    #expect(
      context.terminalCommands.value == [
        .createTabWithInput(context.worktree, input: "$EDITOR", runSetupScriptIfNew: true)
      ]
    )
    await store.finish()
  }

  @Test(.dependencies) func openWorktreeWithInvalidWorktreeIDIsIgnored() async {
    let (store, context) = makeStore()

    await store.send(.repositories(.contextMenuOpenWorktree("nonexistent-id", .terminal)))
    await store.receive(\.repositories.delegate.openWorktreeInApp)
    #expect(context.openedActions.value.isEmpty)
    await store.finish()
  }

  @Test(.dependencies) func openWorktreeWithNoSelectionIsIgnored() async {
    let (store, context) = makeStore { state, _ in state.selection = nil }

    await store.send(.openWorktree(.finder))
    #expect(context.openedActions.value.isEmpty)
    await store.finish()
  }

  @Test(.dependencies) func revealInFinderWithNoSelectionIsIgnored() async {
    let (store, context) = makeStore { state, _ in state.selection = nil }

    await store.send(.revealInFinder)
    #expect(context.openedActions.value.isEmpty)
    await store.finish()
  }

  @Test(.dependencies) func openWorktreeFailedSetsAlert() async {
    let (store, _) = makeStore()

    let error = OpenActionError(title: "Failed", message: "App not found.")
    await store.send(.openWorktreeFailed(error)) {
      $0.alert = AlertState {
        TextState("Failed")
      } actions: {
        ButtonState(role: .cancel, action: .dismiss) {
          TextState("OK")
        }
      } message: {
        TextState("App not found.")
      }
    }
    await store.finish()
  }

  @Test(.dependencies) func openSelectedWorktreeRoutesToSelectedAction() async {
    let (store, context) = makeStore(appState: { $0.openActionSelection = .finder })

    await store.send(.openSelectedWorktree)
    await store.receive(\.openWorktree)
    #expect(context.openedActions.value == [.finder])
    #expect(context.capturedEvents.value == [CapturedEvent(name: "worktree_opened", source: "toolbar")])
    await store.finish()
  }

  // MARK: - Helpers.

  private struct CapturedEvent: Equatable {
    let name: String
    let source: String?
  }

  private struct TestContext {
    let worktree: Worktree
    let openedActions: LockIsolated<[OpenWorktreeAction]>
    let terminalCommands: LockIsolated<[TerminalClient.Command]>
    let capturedEvents: LockIsolated<[CapturedEvent]>
  }

  private func makeStore(
    repositoriesState mutate: (inout RepositoriesFeature.State, Worktree) -> Void = { _, _ in },
    appState mutateApp: (inout AppFeature.State) -> Void = { _ in }
  ) -> (TestStoreOf<AppFeature>, TestContext) {
    let worktree = makeWorktree()
    var repositoriesState = makeRepositoriesState(worktree: worktree)
    mutate(&repositoriesState, worktree)
    let openedActions = LockIsolated<[OpenWorktreeAction]>([])
    let terminalCommands = LockIsolated<[TerminalClient.Command]>([])
    let capturedEvents = LockIsolated<[CapturedEvent]>([])
    let storage = SettingsTestStorage()
    let settingsFileURL = URL(
      fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json"
    )
    var initialState = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    mutateApp(&initialState)
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
      $0.workspaceClient.open = { action, _, _ in
        openedActions.withValue { $0.append(action) }
      }
      $0.terminalClient.send = { command in
        terminalCommands.withValue { $0.append(command) }
      }
      $0.analyticsClient.capture = { event, properties in
        let source = properties?["source"] as? String
        capturedEvents.withValue { $0.append(CapturedEvent(name: event, source: source)) }
      }
    }
    let context = TestContext(
      worktree: worktree,
      openedActions: openedActions,
      terminalCommands: terminalCommands,
      capturedEvents: capturedEvents
    )
    return (store, context)
  }

  private func makeWorktree() -> Worktree {
    let repositoryRootURL = URL(fileURLWithPath: "/tmp/repo-\(UUID().uuidString)")
    let worktreeURL = repositoryRootURL.appending(path: "wt-1")
    return Worktree(
      id: worktreeURL.path(percentEncoded: false),
      name: "wt-1",
      detail: "detail",
      workingDirectory: worktreeURL,
      repositoryRootURL: repositoryRootURL
    )
  }

  private func makeRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    let repository = Repository(
      id: worktree.repositoryRootURL.path(percentEncoded: false),
      rootURL: worktree.repositoryRootURL,
      name: "repo",
      worktrees: [worktree]
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    return repositoriesState
  }
}
