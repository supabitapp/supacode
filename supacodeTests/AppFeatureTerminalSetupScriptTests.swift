import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import SupacodeSettingsFeature
@testable import supacode

@MainActor
struct AppFeatureTerminalSetupScriptTests {
  @Test(.dependencies) func newTerminalConsumesSetupScriptAndSendsCreateTabWithFlag() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: true
    )
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

    await store.send(.newTerminal)
    await store.send(.terminalEvent(.setupScriptConsumed(worktreeID: worktree.id)))
    await store.receive(\.repositories.worktreeCreationSettled)
    await store.receive(\.repositories.sidebarItems) {
      $0.repositories.sidebarItems[id: worktree.id]?.lifecycle = .idle
      $0.repositories.applyPostReduceCacheRecomputes(
        [.sidebarStructure, .selectedWorktreeSlice, .sidebarSelectionSlice]
      )
    }
    await store.finish()
    #expect(sent.value == [.createTab(worktree, runSetupScriptIfNew: true, id: nil)])
  }

  @Test(.dependencies) func newTerminalWithoutSetupScriptDoesNotConsume() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: false,
      selected: true
    )
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

    await store.send(.newTerminal)
    await store.finish()
    #expect(sent.value == [.createTab(worktree, runSetupScriptIfNew: false, id: nil)])
  }

  @Test(.dependencies) func tabCreatedClearsPending() async {
    // A hosted tab is the readiness condition, so `.tabCreated` clears the
    // creation-progress state even when no setup script runs (empty script,
    // skip, or hydrated layout never emit `.setupScriptConsumed`).
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: true
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.terminalEvent(.tabCreated(worktreeID: worktree.id)))
    await store.receive(\.repositories.worktreeCreationSettled)
    await store.receive(\.repositories.sidebarItems) {
      $0.repositories.sidebarItems[id: worktree.id]?.lifecycle = .idle
      $0.repositories.applyPostReduceCacheRecomputes(
        [.sidebarStructure, .selectedWorktreeSlice, .sidebarSelectionSlice]
      )
    }
    await store.finish()
  }

  @Test(.dependencies) func setupScriptConsumedThenTabCreatedClearsOnce() async {
    // The setup-script fast path and the tab-created readiness both clear the
    // same pending latch; the second arrival is an idempotent no-op.
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: true
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.terminalEvent(.setupScriptConsumed(worktreeID: worktree.id)))
    await store.receive(\.repositories.worktreeCreationSettled)
    await store.receive(\.repositories.sidebarItems) {
      $0.repositories.sidebarItems[id: worktree.id]?.lifecycle = .idle
      $0.repositories.applyPostReduceCacheRecomputes(
        [.sidebarStructure, .selectedWorktreeSlice, .sidebarSelectionSlice]
      )
    }
    // The later readiness signal re-fires but the row is already idle: the
    // guard makes it inert (no follow-up `sidebarItems` mutation).
    await store.send(.terminalEvent(.tabCreated(worktreeID: worktree.id)))
    await store.receive(\.repositories.worktreeCreationSettled)
    await store.finish()
  }

  @Test(.dependencies) func surfaceCreationFailedKeepsPending() async {
    // A failure must NOT clear `.pending`: `.surfaceCreationFailed` also covers
    // ordinary tab / split failures, so clearing here would strand an unrelated
    // failure onto the initial bootstrap's overlay.
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: true
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(
      .terminalEvent(.surfaceCreationFailed(worktreeID: worktree.id, attemptedID: UUID(), message: "boom"))
    )
    await store.finish()
    #expect(store.state.repositories.sidebarItems[id: worktree.id]?.lifecycle == .pending)
  }

  @Test(.dependencies) func initialTabCreationFailedSettlesPending() async {
    // A failed initial-tab bootstrap settles the overlay so the worktree shows
    // with no tabs (a valid empty state), unlike an ordinary surface failure.
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: true
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.terminalEvent(.initialTabCreationFailed(worktreeID: worktree.id, message: "boom")))
    await store.receive(\.repositories.worktreeCreationSettled)
    await store.receive(\.repositories.sidebarItems) {
      $0.repositories.sidebarItems[id: worktree.id]?.lifecycle = .idle
      $0.repositories.applyPostReduceCacheRecomputes(
        [.sidebarStructure, .selectedWorktreeSlice, .sidebarSelectionSlice]
      )
    }
    await store.finish()
  }

  @Test(.dependencies) func worktreeCreationSettledIgnoresNonPendingLifecycle() async {
    // The settle only clears `.pending`; a late signal during teardown must not
    // resurrect a `.deleting` row.
    let worktree = makeWorktree()
    var repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: false,
      selected: true
    )
    repositoriesState.sidebarItems[id: worktree.id]?.lifecycle = .deleting
    repositoriesState.applyPostReduceCacheRecomputes()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.terminalEvent(.tabCreated(worktreeID: worktree.id)))
    await store.receive(\.repositories.worktreeCreationSettled)
    await store.finish()
    #expect(store.state.repositories.sidebarItems[id: worktree.id]?.lifecycle == .deleting)
  }

  @Test(.dependencies) func projectionWithSurfacesClearsPending() async {
    // Drop-resistant backstop: a pending row that now hosts a tab is ready,
    // even if the one-shot `.tabCreated` / `.setupScriptConsumed` was missed.
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: true
    )
    // A surface-bearing selected row's cache recompute reads the live
    // date/clock, so supply test values to keep the store hermetic.
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .worktreeProjectionChanged(
          worktree.id,
          WorktreeRowProjection(
            surfaceIDs: [UUID()],
            isProgressBusy: false,
            hasUnseenNotifications: false,
            notifications: []
          )
        )
      )
    )
    await store.receive(\.repositories.worktreeCreationSettled)
    // Drive the follow-up lifecycle flip so the non-exhaustive store applies it
    // before the assertion (the projection also fans out its own
    // `sidebarItems` action, hence exhaustivity off).
    await store.receive(\.repositories.sidebarItems)
    #expect(store.state.repositories.sidebarItems[id: worktree.id]?.lifecycle == .idle)
    await store.finish()
  }

  @Test(.dependencies) func projectionWithoutSurfacesKeepsPending() async {
    // An empty projection is not readiness: the pending latch must survive it.
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: true
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .worktreeProjectionChanged(
          worktree.id,
          WorktreeRowProjection(
            surfaceIDs: [],
            isProgressBusy: false,
            hasUnseenNotifications: false,
            notifications: []
          )
        )
      )
    )
    await store.finish()
    #expect(store.state.repositories.sidebarItems[id: worktree.id]?.lifecycle == .pending)
  }

  @Test(.dependencies) func setupScriptConsumedEventClearsPending() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: true
    )
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }

    await store.send(.terminalEvent(.setupScriptConsumed(worktreeID: worktree.id)))
    await store.receive(\.repositories.worktreeCreationSettled)
    await store.receive(\.repositories.sidebarItems) {
      $0.repositories.sidebarItems[id: worktree.id]?.lifecycle = .idle
      $0.repositories.applyPostReduceCacheRecomputes(
        [.sidebarStructure, .selectedWorktreeSlice, .sidebarSelectionSlice]
      )
    }
    await store.finish()
  }

  @Test(.dependencies) func worktreeCreatedTriggersEnsureInitialTabWithSetupScriptFlag() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: false
    )
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

    await store.send(.repositories(.delegate(.worktreeCreated(worktree))))
    await store.finish()
    #expect(
      sent.value == [
        .ensureInitialTab(worktree, runSetupScriptIfNew: true, focusing: false)
      ]
    )
  }

  @Test(.dependencies) func worktreeCreatedSkipsSetupScriptFlagWhenNotPending() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: false,
      selected: false
    )
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

    await store.send(.repositories(.delegate(.worktreeCreated(worktree))))
    await store.finish()
    #expect(
      sent.value == [
        .ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false)
      ]
    )
  }

  @Test(.dependencies) func selectedWorktreeChangedCarriesSetupScriptFlagForPendingWorktree() async {
    // A freshly created worktree emits `selectedWorktreeChanged` before
    // `worktreeCreated`, so this bootstrap must carry the setup-script intent
    // or the later, setup-aware call finds the tab already made.
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: true,
      selected: true
    )
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let storage = SettingsTestStorage()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
      $0.worktreeInfoWatcher.send = { _ in }
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree))))
    await store.finish()
    #expect(
      sent.value.contains(.ensureInitialTab(worktree, runSetupScriptIfNew: true, focusing: false))
    )
  }

  @Test(.dependencies) func selectedWorktreeChangedOmitsSetupScriptFlagForIdleWorktree() async {
    let worktree = makeWorktree()
    let repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: false,
      selected: true
    )
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let storage = SettingsTestStorage()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
      $0.worktreeInfoWatcher.send = { _ in }
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree))))
    await store.finish()
    #expect(
      sent.value.contains(.ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: false))
    )
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

  @Test(.dependencies) func selectedWorktreeChangedArmsTerminalFocusWhenRequested() async {
    let worktree = makeWorktree()
    var repositoriesState = makeRepositoriesState(
      worktree: worktree,
      pendingSetupScript: false,
      selected: true
    )
    // A launch restore (or a focus-requesting selection) arms this before the
    // delegate fires.
    repositoriesState.sidebarItems[id: worktree.id]?.shouldFocusTerminal = true
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let storage = SettingsTestStorage()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
      $0.worktreeInfoWatcher.send = { _ in }
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(worktree))))
    await store.finish()
    // The activation command carries the focus intent so the host claims focus.
    #expect(sent.value.contains(.ensureInitialTab(worktree, runSetupScriptIfNew: false, focusing: true)))
  }

  private func makeRepositoriesState(
    worktree: Worktree,
    pendingSetupScript: Bool,
    selected: Bool
  ) -> RepositoriesFeature.State {
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: [worktree]
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    if selected {
      repositoriesState.selection = .worktree(worktree.id)
    }
    repositoriesState.reconcileSidebarForTesting()
    if pendingSetupScript {
      repositoriesState.sidebarItems[id: worktree.id]?.lifecycle = .pending
      repositoriesState.applyPostReduceCacheRecomputes()
    }
    return repositoriesState
  }
}
