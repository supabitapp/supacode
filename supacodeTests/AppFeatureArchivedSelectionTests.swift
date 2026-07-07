import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import OrderedCollections
import Sharing
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureArchivedSelectionTests {
  @Test(.dependencies) func selectingArchivedWorktreesDoesNotClearLastFocused() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let worktree = Worktree(
      id: "/tmp/repo/wt1",
      name: "wt1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt1"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: RepositoryID(rootURL.path(percentEncoded: false)),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var repositoriesState = RepositoriesFeature.State(reconciledRepositories: [repository])
    repositoriesState.selection = .worktree(worktree.id)
    let priorFocus = repositoriesState.sidebar.focusedWorktreeID
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
      $0.worktreeInfoWatcher.send = { _ in }
    }

    await store.send(.repositories(.selectArchivedWorktrees)) {
      $0.repositories.selection = .archivedWorktrees
    }
    await store.receive(\.repositories.delegate.selectedWorktreeChanged)
    await store.finish()
    // Selecting the archived list must NOT overwrite the last
    // focused live worktree — the sidebar focus should be
    // untouched so returning from archives restores the prior row.
    #expect(store.state.repositories.sidebar.focusedWorktreeID == priorFocus)
  }

  @Test(.dependencies) func repositoriesChangedPrunesArchivedWorktreesFromTerminalAndRunScriptStatus() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let activeWorktree = Worktree(
      id: "/tmp/repo/wt-active",
      name: "wt-active",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-active"),
      repositoryRootURL: rootURL
    )
    let archivedWorktree = Worktree(
      id: "/tmp/repo/wt-archived",
      name: "wt-archived",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-archived"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: RepositoryID(rootURL.path(percentEncoded: false)),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [activeWorktree, archivedWorktree])
    )
    var repositoriesState = RepositoriesFeature.State(reconciledRepositories: [repository])
    repositoriesState.selection = .worktree(activeWorktree.id)
    repositoriesState.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: archivedWorktree.id,
        in: repository.id,
        bucket: .archived,
        item: .init(archivedAt: Date(timeIntervalSince1970: 1_000_000))
      )
    }
    var appState = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    let scriptID = UUID()
    // Distinct tints per worktree so the pruner is asserted to carry
    // the surviving tint through untouched, not coincidentally match.
    let activeTint: RepositoryColor = .purple
    let archivedTint: RepositoryColor = .orange
    appState.repositories.sidebarItems[id: activeWorktree.id]?.runningScripts[id: scriptID] =
      .init(id: scriptID, tint: activeTint)
    appState.repositories.sidebarItems[id: archivedWorktree.id]?.runningScripts[id: scriptID] =
      .init(id: scriptID, tint: archivedTint)
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.repositoriesChanged([repository]))))
    await store.finish()
    // The reconcile step inside `.repositoriesChanged` clears running scripts on
    // archived rows that aren't deleting; no separate row action is dispatched.
    #expect(
      store.state.repositories.sidebarItems[id: archivedWorktree.id]?.runningScripts.isEmpty == true
    )

    #expect(
      sentCommands.value == [
        .prune(keeping: [activeWorktree.id], protectingRepositoryIDs: [])
      ]
    )
  }

  @Test(.dependencies) func repositoriesChangedProtectsFailedRepositoriesDuringTerminalPrune() async {
    var repositoriesState = RepositoriesFeature.State()
    let failedRepositoryID = RepositoryID("/tmp/repo")
    repositoriesState.loadFailuresByID = [failedRepositoryID: "boom"]
    let appState = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.repositoriesChanged([]))))
    await store.finish()

    #expect(
      sentCommands.value == [
        .prune(keeping: [], protectingRepositoryIDs: [failedRepositoryID])
      ]
    )
  }

  @Test(.dependencies) func repositoriesChangedProtectsEnvironmentBlockedReposDuringTerminalPrune() async {
    // A transient git gate suppresses the repo's rows but must not tear down its
    // live terminal layouts: the blocked root is shielded from prune.
    var repositoriesState = RepositoriesFeature.State()
    let blockedRoot = URL(fileURLWithPath: "/tmp/blocked-repo")
    let blockedID = RepositoryID(blockedRoot.path(percentEncoded: false))
    repositoriesState.repositoryRoots = [blockedRoot]
    repositoriesState.gitEnvironmentError = .xcodeLicenseNotAccepted
    let appState = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.repositoriesChanged([]))))
    await store.finish()

    #expect(
      sentCommands.value == [
        .prune(keeping: [], protectingRepositoryIDs: [blockedID])
      ]
    )
  }

  @Test(.dependencies) func repositoriesChangedRehydratesAgentPresenceFromRestore() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let worktree = Worktree(
      id: "/tmp/repo/wt-feature",
      name: "feature",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-feature"),
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: RepositoryID(rootURL.path(percentEncoded: false)),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    // Simulate the launch-time race: restore landed before the roster, so
    // agent presence is populated but the surface-to-row index was empty when
    // the fan-out fired. Seed `surfaceIDs` + `pendingAgentRehydrateSurfaces`
    // by hand to stand in for the layout-seeding path covered by
    // `reconcileSeedsSurfaceIDsFromPersistedLayout`.
    let surfaceID = UUID()
    var repositoriesState = RepositoriesFeature.State(reconciledRepositories: [repository])
    repositoriesState.sidebarItems[id: worktree.id]?.surfaceIDs = [surfaceID]
    repositoriesState.pendingAgentRehydrateSurfaces = [surfaceID]
    var appState = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    appState.agentPresence.bySurface[surfaceID] = [.claude]
    appState.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    ] = AgentPresenceFeature.PresenceRecord(activity: .awaitingInput, pids: [42])

    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.delegate(.repositoriesChanged([repository]))))
    await store.receive(
      \.repositories.sidebarItems[id: worktree.id].agentSnapshotChanged
    ) {
      $0.repositories.sidebarItems[id: worktree.id]?.agents = [
        AgentPresenceFeature.AgentInstance(agent: .claude, activity: .awaitingInput)
      ]
    }
    await store.finish()
    let row = store.state.repositories.sidebarItems[id: worktree.id]
    #expect(row?.hasAgentAwaitingInput == true)
    // Drained, so it won't re-fire on subsequent `repositoriesChanged`.
    #expect(store.state.repositories.pendingAgentRehydrateSurfaces.isEmpty)
    // User-visible invariant: the row is in the Active hoist now.
    let activeRowIDs = store.state.repositories.sidebarStructure.sections.flatMap {
      section -> [Worktree.ID] in
      if case .highlight(let kind, let rowIDs) = section, kind == .active { return rowIDs }
      return []
    }
    #expect(activeRowIDs.contains(worktree.id))
  }

  @Test(.dependencies) func agentPresenceDeltaPersistsLayoutsAfterDebounceWindow() async {
    let surfaceID = UUID()
    var appState = AppFeature.State(
      repositories: RepositoriesFeature.State(),
      settings: SettingsFeature.State()
    )
    appState.agentPresence.bySurface[surfaceID] = [.claude]
    appState.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    ] = AgentPresenceFeature.PresenceRecord(activity: .busy, pids: [42])
    let savedAgents = LockIsolated<[UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]]?>(nil)
    let clock = TestClock()

    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.terminalClient.saveLayoutsWithAgents = { agents in
        savedAgents.setValue(agents)
      }
    }
    store.exhaustivity = .off

    await store.send(.agentPresence(.delegate(.surfacesChanged([surfaceID]))))
    // Pre-debounce: nothing persisted yet.
    #expect(savedAgents.value == nil)
    await clock.advance(by: .seconds(1))
    await store.finish()
    let written = savedAgents.value
    #expect(written?[surfaceID]?.first?.agent == SkillAgent.claude.rawValue)
    #expect(written?[surfaceID]?.first?.activity == AgentPresenceFeature.Activity.busy.rawValue)
  }

  @Test(.dependencies) func presenceDeltaWithinDebounceWindowCoalescesIntoOneWrite() async {
    let surfaceID = UUID()
    var appState = AppFeature.State(
      repositories: RepositoriesFeature.State(),
      settings: SettingsFeature.State()
    )
    appState.agentPresence.bySurface[surfaceID] = [.claude]
    appState.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    ] = AgentPresenceFeature.PresenceRecord(activity: .busy, pids: [42])
    let writeCount = LockIsolated(0)
    let clock = TestClock()

    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.terminalClient.saveLayoutsWithAgents = { _ in
        writeCount.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off

    // Two deltas within the same 1s window: the second send must cancel the
    // first in-flight task via `cancelInFlight: true`, so only the second
    // task's save survives.
    await store.send(.agentPresence(.delegate(.surfacesChanged([surfaceID]))))
    await clock.advance(by: .milliseconds(500))
    await store.send(.agentPresence(.delegate(.surfacesChanged([surfaceID]))))
    await clock.advance(by: .seconds(1))
    await store.finish()
    #expect(writeCount.value == 1)
  }
}
