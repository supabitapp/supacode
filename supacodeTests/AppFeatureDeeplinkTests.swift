import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct AppFeatureDeeplinkTests {
  // MARK: - Routing after load.

  @Test(.dependencies) func selectWorktreeDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .select)))
    await store.receive(\.repositories.selectWorktree)
  }

  @Test(.dependencies) func runWorktreeDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .run)))
    await store.receive(\.repositories.selectWorktree)
    await store.receive(\.runScript)
  }

  @Test(.dependencies) func pinWorktreeDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .pin)))
    await store.receive(\.repositories.pinWorktree)
  }

  @Test(.dependencies) func unpinWorktreeDeeplink() async {
    let worktree = makeWorktree()
    var repositories = makeRepositoriesState(worktree: worktree)
    repositories.pinnedWorktreeIDs = [worktree.id]
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .unpin)))
    await store.receive(\.repositories.unpinWorktree)
  }

  @Test(.dependencies) func archiveWorktreeDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .archive)))
    await store.receive(\.repositories.requestArchiveWorktree)
  }

  @Test(.dependencies) func archiveWorktreeDeeplinkWithUnknownIDShowsAlert() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: "/nonexistent", action: .archive)))
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func deleteWorktreeDeeplinkShowsConfirmation() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .delete)))
    #expect(store.state.deeplinkInputConfirmation?.message == .confirmation("Delete worktree \"wt-1\"?"))
    #expect(store.state.deeplinkInputConfirmation?.action == .delete)
  }

  @Test(.dependencies) func deleteWorktreeDeeplinkSkipsConfirmationWhenSettingEnabled() async {
    let worktree = makeWorktree()
    var settings = SettingsFeature.State()
    settings.allowArbitraryDeeplinkInput = true
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings,
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .delete)))
    #expect(store.state.deeplinkInputConfirmation == nil)
    await store.receive(\.repositories.deleteWorktreeConfirmed)
  }

  @Test(.dependencies) func deleteWorktreeDeeplinkConfirmationAcceptedSendsDeleteConfirmed() async {
    let worktree = makeWorktree()
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.deeplinkInputConfirmation = DeeplinkInputConfirmationFeature.State(
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      repositoryName: "repo",
      message: .confirmation("Delete worktree \"wt-1\"?"),
      action: .delete,
    )
    let store = TestStore(initialState: initialState) {
      AppFeature()
    }
    store.exhaustivity = .off

    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(
        .deeplinkInputConfirmation(
          .presented(
            .delegate(
              .confirm(worktreeID: worktree.id, action: .delete, alwaysAllow: false)))
        )
      ) {
        $0.deeplinkInputConfirmation = nil
      }
    }
    await store.receive(\.repositories.deleteWorktreeConfirmed)
    await store.finish()
  }

  @Test(.dependencies) func deleteMainWorktreeDeeplinkShowsDeleteNotAllowed() async {
    let mainWorktree = makeWorktree(id: "/tmp/repo", name: "repo")
    let store = makeStore(worktree: mainWorktree)

    await store.send(.deeplink(.worktree(id: mainWorktree.id, action: .delete)))
    #expect(store.state.deeplinkInputConfirmation == nil)
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func deleteWorktreeDeeplinkWithUnknownIDShowsAlert() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: "/nonexistent", action: .delete)))
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func unarchiveWorktreeDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .unarchive)))
    await store.receive(\.repositories.unarchiveWorktree)
  }

  @Test(.dependencies) func stopWorktreeDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .stop)))
    await store.receive(\.repositories.selectWorktree)
    await store.receive(\.stopRunScript)
  }

  // MARK: - Help deeplink.

  @Test(.dependencies) func helpDeeplinkSetsCheatsheetRequested() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.help)) {
      $0.isDeeplinkCheatsheetRequested = true
    }
  }

  @Test(.dependencies) func deeplinkCheatsheetOpenedResetsFlag() async {
    let worktree = makeWorktree()
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.isDeeplinkCheatsheetRequested = true
    let store = TestStore(initialState: initialState) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.deeplinkCheatsheetOpened) {
      $0.isDeeplinkCheatsheetRequested = false
    }
  }

  // MARK: - Destructive deeplink actions.

  @Test(.dependencies) func tabDestroyShowsConfirmationWhenSettingDisabled() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .tabDestroy(tabID: tabUUID))))
    #expect(store.state.deeplinkInputConfirmation != nil)
  }

  @Test(.dependencies) func tabDestroySkipsConfirmationWhenSettingEnabled() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var settings = SettingsFeature.State()
    settings.allowArbitraryDeeplinkInput = true
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings,
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
      $0.terminalClient.tabExists = { _, _ in true }
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .tabDestroy(tabID: tabUUID))))
    #expect(store.state.deeplinkInputConfirmation == nil)
    let hasDestroy = sent.value.contains(where: {
      if case .destroyTab = $0 { return true }
      return false
    })
    #expect(hasDestroy)
  }

  @Test(.dependencies) func surfaceDestroyShowsConfirmationWhenSettingDisabled() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let store = makeStore(worktree: worktree)

    await store.send(
      .deeplink(.worktree(id: worktree.id, action: .surfaceDestroy(tabID: tabUUID, surfaceID: surfaceUUID))))
    #expect(store.state.deeplinkInputConfirmation != nil)
  }

  @Test(.dependencies) func surfaceDestroySkipsConfirmationWhenSettingEnabled() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var settings = SettingsFeature.State()
    settings.allowArbitraryDeeplinkInput = true
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings,
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.surfaceExists = { _, _, _ in true }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(.worktree(id: worktree.id, action: .surfaceDestroy(tabID: tabUUID, surfaceID: surfaceUUID))))
    #expect(store.state.deeplinkInputConfirmation == nil)
    let hasDestroy = sent.value.contains(where: {
      if case .destroySurface = $0 { return true }
      return false
    })
    #expect(hasDestroy)
  }

  @Test(.dependencies) func surfaceWithInputShowsConfirmation() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let store = makeStore(worktree: worktree)

    await store.send(
      .deeplink(
        .worktree(
          id: worktree.id, action: .surface(tabID: tabUUID, surfaceID: surfaceUUID, input: "echo test"))))
    #expect(store.state.deeplinkInputConfirmation != nil)
    #expect(store.state.deeplinkInputConfirmation?.message == .command("echo test"))
  }

  @Test(.dependencies) func surfaceSplitWithInputShowsConfirmation() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let store = makeStore(worktree: worktree)

    await store.send(
      .deeplink(
        .worktree(
          id: worktree.id,
          action: .surfaceSplit(
            tabID: tabUUID, surfaceID: surfaceUUID, direction: .horizontal, input: "echo test", id: nil))))
    #expect(store.state.deeplinkInputConfirmation != nil)
    #expect(store.state.deeplinkInputConfirmation?.message == .command("echo test"))
  }

  @Test(.dependencies) func surfaceSplitWithoutInputSkipsConfirmation() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State(),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.surfaceExists = { _, _, _ in true }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(
          id: worktree.id,
          action: .surfaceSplit(
            tabID: tabUUID, surfaceID: surfaceUUID, direction: .vertical, input: nil, id: nil))))
    #expect(store.state.deeplinkInputConfirmation == nil)
    let hasSplit = sent.value.contains(where: {
      if case .splitSurface = $0 { return true }
      return false
    })
    #expect(hasSplit)
  }

  @Test(.dependencies) func surfaceSplitWithInputConfirmationAcceptedSendsCommand() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.deeplinkInputConfirmation = DeeplinkInputConfirmationFeature.State(
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      repositoryName: "repo",
      message: .command("echo test"),
      action: .surfaceSplit(
        tabID: tabUUID, surfaceID: surfaceUUID, direction: .horizontal, input: "echo test", id: nil),
    )
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.surfaceExists = { _, _, _ in true }
    }
    store.exhaustivity = .off

    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(
        .deeplinkInputConfirmation(
          .presented(
            .delegate(
              .confirm(
                worktreeID: worktree.id,
                action: .surfaceSplit(
                  tabID: tabUUID, surfaceID: surfaceUUID, direction: .horizontal,
                  input: "echo test", id: nil),
                alwaysAllow: false)))
        )
      ) {
        $0.deeplinkInputConfirmation = nil
      }
    }
    let hasSplit = sent.value.contains(where: {
      if case .splitSurface = $0 { return true }
      return false
    })
    #expect(hasSplit)
  }

  @Test(.dependencies) func settingsDeeplinkOpensGeneral() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.settings(section: nil)))
    await store.receive(\.settings.setSelection)
  }

  @Test(.dependencies) func settingsDeeplinkOpensSpecificSection() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.settings(section: .worktrees)))
    await store.receive(\.settings.setSelection)
  }

  @Test(.dependencies) func settingsRepoDeeplinkOpensRepoSettings() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.settingsRepo(repositoryID: "/tmp/repo")))
    await store.receive(\.settings.setSelection)
  }

  @Test(.dependencies) func settingsRepoDeeplinkWithUnknownRepoShowsAlert() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.settingsRepo(repositoryID: "/nonexistent")))
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func repoOpenDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.repoOpen(path: URL(fileURLWithPath: "/tmp/new-repo"))))
    await store.receive(\.repositories.openRepositories)
  }

  @Test(.dependencies) func repoWorktreeNewWithoutBranchDeeplink() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(
      .deeplink(
        .repoWorktreeNew(
          repositoryID: "/tmp/repo",
          branch: nil,
          baseRef: nil,
          fetchOrigin: false
        )
      )
    )
    await store.receive(\.repositories.createRandomWorktreeInRepository)
  }

  // MARK: - Trailing slash normalization.

  @Test(.dependencies) func worktreeIDWithoutTrailingSlashMatchesWorktreeWithSlash() async {
    // Worktree IDs from standardizedFileURL have a trailing slash.
    let worktree = makeWorktree(id: "/tmp/repo/wt-1/")
    let store = makeStore(worktree: worktree)

    // Deeplink uses ID without trailing slash.
    await store.send(.deeplink(.worktree(id: "/tmp/repo/wt-1", action: .select)))
    await store.receive(\.repositories.selectWorktree)
  }

  // MARK: - Unknown worktree alert.

  @Test(.dependencies) func unknownWorktreeShowsAlert() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: "/nonexistent", action: .select)))
    #expect(store.state.alert != nil)
  }

  // MARK: - Tab actions.

  @Test(.dependencies) func worktreeTabWithValidTabID() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
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
      $0.terminalClient.tabExists = { _, _ in true }
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .tab(tabID: tabUUID))))
    await store.receive(\.repositories.selectWorktree)
    let expected = TerminalClient.Command.selectTab(worktree, tabID: TerminalTabID(rawValue: tabUUID))
    #expect(sent.value.contains(expected))
  }

  // MARK: - Tab new with input confirmation.

  @Test(.dependencies) func tabNewWithInputShowsConfirmationSheet() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(.deeplink(.worktree(id: worktree.id, action: .tabNew(input: "echo hello", id: nil))))
    #expect(store.state.deeplinkInputConfirmation != nil)
    #expect(store.state.deeplinkInputConfirmation?.message == .command("echo hello"))
    #expect(store.state.deeplinkInputConfirmation?.worktreeID == worktree.id)
  }

  @Test(.dependencies) func tabNewWithInputSkipsConfirmationWhenSettingEnabled() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var settings = SettingsFeature.State()
    settings.allowArbitraryDeeplinkInput = true
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings,
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .tabNew(input: "echo hello", id: nil))))
    #expect(store.state.deeplinkInputConfirmation == nil)
    #expect(
      sent.value.contains(
        .createTabWithInput(worktree, input: "echo hello", runSetupScriptIfNew: false, id: nil)
      )
    )
  }

  @Test(.dependencies) func tabNewConfirmationAcceptedSendsTerminalCommand() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.deeplinkInputConfirmation = makeConfirmationState(worktree: worktree, input: "echo hello")
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(
        .deeplinkInputConfirmation(
          .presented(
            .delegate(
              .confirm(worktreeID: worktree.id, action: .tabNew(input: "echo hello", id: nil), alwaysAllow: false)))
        )
      ) {
        $0.deeplinkInputConfirmation = nil
      }
    }
    #expect(
      sent.value.contains(
        .createTabWithInput(worktree, input: "echo hello", runSetupScriptIfNew: false, id: nil)
      )
    )
    await store.finish()
  }

  @Test(.dependencies) func tabNewConfirmationWithAlwaysAllowPersistsSetting() async {
    let worktree = makeWorktree()
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.deeplinkInputConfirmation = makeConfirmationState(worktree: worktree, input: "echo hello")
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(
        .deeplinkInputConfirmation(
          .presented(
            .delegate(
              .confirm(worktreeID: worktree.id, action: .tabNew(input: "echo hello", id: nil), alwaysAllow: true)))
        )
      ) {
        $0.deeplinkInputConfirmation = nil
      }
    }
    // The setting is persisted via SettingsFeature, not mutated directly.
    await store.receive(\.settings.setAllowArbitraryDeeplinkInput) {
      $0.settings.allowArbitraryDeeplinkInput = true
    }
    await store.finish()
  }

  @Test(.dependencies) func tabNewConfirmationCancelledDoesNothing() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State(),
    )
    initialState.deeplinkInputConfirmation = makeConfirmationState(worktree: worktree, input: "echo hello")
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(.deeplinkInputConfirmation(.presented(.delegate(.cancel)))) {
        $0.deeplinkInputConfirmation = nil
      }
    }
    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func tabNewConfirmationWithDeletedWorktreeDoesNothing() async {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = AppFeature.State(
      repositories: RepositoriesFeature.State(),
      settings: SettingsFeature.State(),
    )
    initialState.deeplinkInputConfirmation = makeConfirmationState(
      worktreeID: "/nonexistent",
      worktreeName: "unknown",
      repositoryName: nil,
      input: "echo hello",
    )
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(
        .deeplinkInputConfirmation(
          .presented(
            .delegate(
              .confirm(
                worktreeID: "/nonexistent", action: .tabNew(input: "echo hello", id: nil), alwaysAllow: false)))
        )
      ) {
        $0.deeplinkInputConfirmation = nil
      }
    }
    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func tabNewWithoutInputCreatesNewTerminal() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State(),
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .tabNew(input: nil, id: nil))))
    let hasCreateTab = sent.value.contains(where: {
      if case .createTab(let target, _, _) = $0 { return target.id == worktree.id }
      return false
    })
    #expect(hasCreateTab)
  }

  // MARK: - Queuing before load.

  @Test(.dependencies) func deeplinkQueuedBeforeLoadAndFlushedAfter() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktree: worktree)
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [repository]
    repositories.selection = .worktree(worktree.id)
    repositories.isInitialLoadComplete = false
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      let worktreeID = worktree.id
      $0[DeeplinkClient.self].parse = { _ in .worktree(id: worktreeID, action: .select) }
    }
    store.exhaustivity = .off

    await store.send(.deeplinkReceived(URL(string: "supacode://worktree/x")!)) {
      $0.pendingDeeplinks = [.worktree(id: worktree.id, action: .select)]
    }

    let repos = IdentifiedArray(uniqueElements: [repository])
    await store.send(.repositories(.delegate(.repositoriesChanged(repos)))) {
      $0.pendingDeeplinks = []
    }
    await store.receive(\.deeplink)
    await store.receive(\.repositories.selectWorktree)
  }

  @Test(.dependencies) func multipleDeeplinksQueuedBeforeLoadAllFlushed() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktree: worktree)
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [repository]
    repositories.selection = .worktree(worktree.id)
    repositories.isInitialLoadComplete = false
    let callCount = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      let worktreeID = worktree.id
      $0[DeeplinkClient.self].parse = { _ in
        let current = callCount.withValue { value -> Int in
          value += 1
          return value
        }
        return current == 1
          ? .worktree(id: worktreeID, action: .pin)
          : .worktree(id: worktreeID, action: .select)
      }
    }
    store.exhaustivity = .off

    // First deeplink queued.
    await store.send(.deeplinkReceived(URL(string: "supacode://first")!)) {
      $0.pendingDeeplinks = [.worktree(id: worktree.id, action: .pin)]
    }
    // Second deeplink appended.
    await store.send(.deeplinkReceived(URL(string: "supacode://second")!)) {
      $0.pendingDeeplinks = [
        .worktree(id: worktree.id, action: .pin),
        .worktree(id: worktree.id, action: .select),
      ]
    }

    let repos = IdentifiedArray(uniqueElements: [repository])
    await store.send(.repositories(.delegate(.repositoriesChanged(repos)))) {
      $0.pendingDeeplinks = []
    }
    // Both deeplinks should be dispatched (pin from first, select from second).
    await store.receive(\.deeplink)
    await store.receive(\.deeplink)
    await store.receive(\.repositories.pinWorktree)
    await store.receive(\.repositories.selectWorktree)
  }

  // MARK: - URL parsing integration.

  @Test(.dependencies) func deeplinkReceivedParsesAndDispatches() async {
    let worktree = makeWorktree()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0[DeeplinkClient.self] = .liveValue
    }
    store.exhaustivity = .off

    let encoded = worktree.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    let url = URL(string: "supacode://worktree/\(encoded)")!
    await store.send(.deeplinkReceived(url))
    await store.receive(\.deeplink)
    await store.receive(\.repositories.selectWorktree)
  }

  @Test(.dependencies) func deeplinkReceivedWithUnknownURLShowsAlert() async {
    let worktree = makeWorktree()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0[DeeplinkClient.self] = .liveValue
    }
    store.exhaustivity = .off

    await store.send(.deeplinkReceived(URL(string: "https://example.com")!))
    // Non-supacode scheme is silently ignored (debug log only, no alert).
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func deeplinkReceivedWithUnrecognizedHostShowsAlert() async {
    let worktree = makeWorktree()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0[DeeplinkClient.self] = .liveValue
    }
    store.exhaustivity = .off

    await store.send(.deeplinkReceived(URL(string: "supacode://unknown-host")!))
    #expect(store.state.alert != nil)
  }

  // MARK: - repositoriesLoaded flush.

  @Test(.dependencies) func deeplinkQueuedBeforeLoadAndFlushedOnRepositoriesLoaded() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktree: worktree)
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [repository]
    repositories.selection = .worktree(worktree.id)
    repositories.isInitialLoadComplete = false
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      let worktreeID = worktree.id
      $0[DeeplinkClient.self].parse = { _ in .worktree(id: worktreeID, action: .select) }
    }
    store.exhaustivity = .off

    await store.send(.deeplinkReceived(URL(string: "supacode://worktree/x")!)) {
      $0.pendingDeeplinks = [.worktree(id: worktree.id, action: .select)]
    }

    // Flush via repositoriesLoaded instead of repositoriesChanged delegate.
    await store.send(.repositories(.repositoriesLoaded([repository], failures: [], roots: [], animated: false))) {
      $0.pendingDeeplinks = []
    }
    await store.receive(\.deeplink)
    await store.receive(\.repositories.selectWorktree)
  }

  // MARK: - openRepositoriesFinished flush.

  @Test(.dependencies) func deeplinkQueuedBeforeLoadAndFlushedOnOpenRepositoriesFinished() async {
    let worktree = makeWorktree()
    let repository = makeRepository(worktree: worktree)
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [repository]
    repositories.selection = .worktree(worktree.id)
    repositories.isInitialLoadComplete = false
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      let worktreeID = worktree.id
      $0[DeeplinkClient.self].parse = { _ in .worktree(id: worktreeID, action: .select) }
    }
    store.exhaustivity = .off

    await store.send(.deeplinkReceived(URL(string: "supacode://worktree/x")!)) {
      $0.pendingDeeplinks = [.worktree(id: worktree.id, action: .select)]
    }

    // Flush via openRepositoriesFinished instead of repositoriesLoaded or repositoriesChanged.
    await store.send(
      .repositories(.openRepositoriesFinished([repository], failures: [], invalidRoots: [], roots: []))
    ) {
      $0.pendingDeeplinks = []
    }
    await store.receive(\.deeplink)
    await store.receive(\.repositories.selectWorktree)
  }

  // MARK: - repoWorktreeNew with branch through store.

  @Test(.dependencies) func repoWorktreeNewWithBranchDeeplink() async {
    let worktree = makeWorktree()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .repoWorktreeNew(
          repositoryID: "/tmp/repo",
          branch: "feature-x",
          baseRef: "main",
          fetchOrigin: true
        )
      )
    )
    await store.receive(\.repositories.createWorktreeInRepository)
    await store.finish()
  }

  @Test(.dependencies) func repoWorktreeNewWithUnknownRepoShowsAlert() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree)

    await store.send(
      .deeplink(.repoWorktreeNew(repositoryID: "/nonexistent", branch: nil, baseRef: nil, fetchOrigin: false)))
    #expect(store.state.alert != nil)
  }

  // MARK: - Surface focus without input.

  @Test(.dependencies) func surfaceFocusWithoutInputSendsTerminalCommand() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
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
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.surfaceExists = { _, _, _ in true }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .surface(tabID: tabUUID, surfaceID: surfaceUUID, input: nil))))
    #expect(store.state.deeplinkInputConfirmation == nil)
    let hasFocus = sent.value.contains(where: {
      if case .focusSurface = $0 { return true }
      return false
    })
    #expect(hasFocus)
  }

  // MARK: - Tab/surface not found alerts.

  @Test(.dependencies) func tabNotFoundShowsAlert() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, _ in false }
    }
    store.exhaustivity = .off

    await store.send(.deeplink(.worktree(id: worktree.id, action: .tab(tabID: tabUUID))))
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func surfaceNotFoundShowsAlert() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.surfaceExists = { _, _, _ in false }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .surface(tabID: tabUUID, surfaceID: surfaceUUID, input: nil))))
    #expect(store.state.alert != nil)
  }

  @Test(.dependencies) func surfaceWithInputValidatesBeforeConfirmation() async {
    let worktree = makeWorktree()
    let tabUUID = UUID()
    let surfaceUUID = UUID()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.surfaceExists = { _, _, _ in false }
    }
    store.exhaustivity = .off

    // Surface doesn't exist — should show "not found" alert, not input confirmation.
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .surface(tabID: tabUUID, surfaceID: surfaceUUID, input: "echo test"))))
    #expect(store.state.alert != nil)
    #expect(store.state.deeplinkInputConfirmation == nil)
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

  private func makeRepository(worktree: Worktree) -> Repository {
    Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: [worktree],
    )
  }

  private func makeRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    let repository = makeRepository(worktree: worktree)
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    repositoriesState.isInitialLoadComplete = true
    return repositoriesState
  }

  private func makeStore(worktree: Worktree) -> TestStoreOf<AppFeature> {
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.surfaceExists = { _, _, _ in true }
    }
    store.exhaustivity = .off
    return store
  }

  private func makeConfirmationState(
    worktree: Worktree,
    input: String
  ) -> DeeplinkInputConfirmationFeature.State {
    makeConfirmationState(
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      repositoryName: "repo",
      input: input,
    )
  }

  private func makeConfirmationState(
    worktreeID: Worktree.ID,
    worktreeName: String,
    repositoryName: String?,
    input: String
  ) -> DeeplinkInputConfirmationFeature.State {
    DeeplinkInputConfirmationFeature.State(
      worktreeID: worktreeID,
      worktreeName: worktreeName,
      repositoryName: repositoryName,
      message: .command(input),
      action: .tabNew(input: input, id: nil),
    )
  }
}
