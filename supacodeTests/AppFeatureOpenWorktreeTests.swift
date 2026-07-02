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
    let (store, context) = makeStore { $0.sidebarItems[id: $1.id]?.lifecycle = .pending }

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

  @Test(.dependencies, arguments: [OpenWorktreeAction.zed, .zedPreview])
  func remoteWorktreeOpensThroughWorkspaceClientWithRemoteAnalytics(action: OpenWorktreeAction) async {
    let worktree = Self.makeRemoteWorktree()
    let (store, context) = makeStore(worktree: worktree)

    await store.send(.repositories(.contextMenuOpenWorktree(worktree.id, action)))
    await store.receive(\.repositories.delegate.openWorktreeInApp)
    #expect(context.openedActions.value == [action])
    #expect(
      context.capturedEvents.value == [
        CapturedEvent(name: "worktree_opened", source: "contextMenu", remote: "true")
      ]
    )
    await store.finish()
  }

  @Test(.dependencies) func revealInFinderOnRemoteWorktreeReportsUnsupported() async {
    let worktree = Self.makeRemoteWorktree()
    let (store, context) = makeStore(worktree: worktree)
    let expectedError = OpenActionError(
      title: "Can't reveal remote worktree",
      message: "Reveal in Finder isn't available for remote SSH worktrees."
    )

    await store.send(.revealInFinder)
    await store.receive(\.openWorktreeFailed) { $0.alert = Self.openFailureAlert(expectedError) }
    #expect(context.openedActions.value.isEmpty)
    #expect(context.capturedEvents.value.isEmpty)
    await store.finish()
  }

  // Drives the toolbar `.openWorktree` path directly (rather than
  // `.openSelectedWorktree`, which install-gates the action through
  // `availableSelection` and would be non-deterministic on a CI host without
  // the editor installed). The capability gate the reducer consults
  // (`remoteOpenInvocation`) is install-independent, so this is the
  // deterministic surface for the capable / non-capable distinction.
  @Test(.dependencies) func openRemoteWorktreeWithCapableEditorRoutesThroughWorkspaceClient() async {
    let worktree = Self.makeRemoteWorktree()
    let (store, context) = makeStore(worktree: worktree)

    await store.send(.openWorktree(.zed))
    #expect(context.openedActions.value == [.zed])
    #expect(
      context.capturedEvents.value == [
        CapturedEvent(name: "worktree_opened", source: "toolbar", remote: "true")
      ]
    )
    await store.finish()
  }

  @Test(.dependencies) func openRemoteWorktreeWithVSCodeRoutesThroughWorkspaceClient() async {
    let worktree = Self.makeRemoteWorktree()
    let (store, context) = makeStore(worktree: worktree)

    await store.send(.openWorktree(.vscode))
    #expect(context.openedActions.value == [.vscode])
    #expect(
      context.capturedEvents.value == [
        CapturedEvent(name: "worktree_opened", source: "toolbar", remote: "true")
      ]
    )
    await store.finish()
  }

  @Test(.dependencies) func openRemoteWorktreeWithVSCodeOnNonDefaultPortReportsUnsupported() async {
    // A non-default-port host can't be expressed as `ssh-remote+host:port`, so
    // `remoteOpenInvocation` is `nil` and the reducer surfaces the port reason.
    let worktree = Self.makeRemoteWorktree(port: 2222)
    let (store, context) = makeStore(worktree: worktree)
    let expectedError = OpenActionError(
      title: "Can't open in \(OpenWorktreeAction.vscode.title)",
      message: "Opening \(OpenWorktreeAction.vscode.title) over SSH needs the port in ~/.ssh/config"
    )

    await store.send(.openWorktree(.vscode))
    await store.receive(\.openWorktreeFailed) { $0.alert = Self.openFailureAlert(expectedError) }
    #expect(context.openedActions.value.isEmpty)
    #expect(context.capturedEvents.value.isEmpty)
    await store.finish()
  }

  @Test(.dependencies) func openRemoteWorktreeWithNonCapableEditorReportsUnsupported() async {
    let worktree = Self.makeRemoteWorktree()
    let (store, context) = makeStore(worktree: worktree)
    let expectedError = OpenActionError(
      title: "Can't open in \(OpenWorktreeAction.intellij.title)",
      message: "\(OpenWorktreeAction.intellij.title) doesn't support opening remote SSH worktrees."
    )

    await store.send(.openWorktree(.intellij))
    await store.receive(\.openWorktreeFailed) { $0.alert = Self.openFailureAlert(expectedError) }
    #expect(context.openedActions.value.isEmpty)
    #expect(context.capturedEvents.value.isEmpty)
    await store.finish()
  }

  @Test(.dependencies) func missingRemoteWorktreeIsIgnored() async {
    let worktree = Self.makeRemoteWorktree(isMissing: true)
    let (store, context) = makeStore(worktree: worktree)

    await store.send(.repositories(.contextMenuOpenWorktree(worktree.id, .zed)))
    await store.receive(\.repositories.delegate.openWorktreeInApp)
    #expect(context.openedActions.value.isEmpty)
    #expect(context.capturedEvents.value.isEmpty)
    await store.finish()
  }

  @Test(.dependencies) func remoteWorktreeWithNonRemoteEditorReportsUnsupported() async {
    let worktree = Self.makeRemoteWorktree()
    let (store, context) = makeStore(worktree: worktree)
    let expectedError = OpenActionError(
      title: "Can't open in \(OpenWorktreeAction.intellij.title)",
      message: "\(OpenWorktreeAction.intellij.title) doesn't support opening remote SSH worktrees."
    )

    await store.send(.repositories(.contextMenuOpenWorktree(worktree.id, .intellij)))
    await store.receive(\.repositories.delegate.openWorktreeInApp)
    await store.receive(\.openWorktreeFailed) { $0.alert = Self.openFailureAlert(expectedError) }
    #expect(context.openedActions.value.isEmpty)
    #expect(context.capturedEvents.value.isEmpty)
    await store.finish()
  }

  @Test(.dependencies) func remoteWorktreeWithEditorActionReportsUnsupportedAndCreatesNoTerminalTab() async {
    let worktree = Self.makeRemoteWorktree()
    let (store, context) = makeStore(worktree: worktree)
    let expectedError = OpenActionError(
      title: "Can't open in \(OpenWorktreeAction.editor.title)",
      message: "\(OpenWorktreeAction.editor.title) doesn't support opening remote SSH worktrees."
    )

    await store.send(.repositories(.contextMenuOpenWorktree(worktree.id, .editor)))
    await store.receive(\.repositories.delegate.openWorktreeInApp)
    await store.receive(\.openWorktreeFailed) { $0.alert = Self.openFailureAlert(expectedError) }
    #expect(context.openedActions.value.isEmpty)
    #expect(context.terminalCommands.value.isEmpty)
    #expect(context.capturedEvents.value.isEmpty)
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
    var remote: String?
  }

  private struct TestContext {
    let worktree: Worktree
    let openedActions: LockIsolated<[OpenWorktreeAction]>
    let terminalCommands: LockIsolated<[TerminalClient.Command]>
    let capturedEvents: LockIsolated<[CapturedEvent]>
  }

  private func makeStore(
    worktree: Worktree? = nil,
    repositoriesState mutate: (inout RepositoriesFeature.State, Worktree) -> Void = { _, _ in },
    appState mutateApp: (inout AppFeature.State) -> Void = { _ in }
  ) -> (TestStoreOf<AppFeature>, TestContext) {
    let worktree = worktree ?? makeWorktree()
    var repositoriesState = makeRepositoriesState(worktree: worktree)
    repositoriesState.reconcileSidebarForTesting()
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
        let remote = properties?["remote"] as? String
        capturedEvents.withValue {
          $0.append(CapturedEvent(name: event, source: source, remote: remote))
        }
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
      id: WorktreeID(worktreeURL.path(percentEncoded: false)),
      name: "wt-1",
      detail: "detail",
      workingDirectory: worktreeURL,
      repositoryRootURL: repositoryRootURL
    )
  }

  private static func makeRemoteWorktree(isMissing: Bool = false, port: Int? = nil) -> Worktree {
    let host = RemoteHost(alias: "devbox", port: port)
    return Worktree(
      location: .remote(host, workingDirectory: "/home/me/proj", repositoryRoot: "/home/me/proj"),
      kind: .git,
      name: "proj",
      detail: host.sshDestination,
      isMissing: isMissing
    )
  }

  private static func openFailureAlert(_ error: OpenActionError) -> AlertState<AppFeature.Alert> {
    AlertState {
      TextState(error.title)
    } actions: {
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("OK")
      }
    } message: {
      TextState(error.message)
    }
  }

  private func makeRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    let repository: Repository =
      worktree.host.map { host in
        Repository(
          location: .remote(host, path: worktree.repositoryRootURL.path(percentEncoded: false)),
          kind: .git,
          name: "repo",
          worktrees: [worktree]
        )
      }
      ?? Repository(
        id: RepositoryID(worktree.repositoryRootURL.path(percentEncoded: false)),
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
