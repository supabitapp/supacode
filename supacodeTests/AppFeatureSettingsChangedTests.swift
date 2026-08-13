import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureSettingsChangedTests {
  @Test(.dependencies) func settingsChangedPropagatesRepositorySettings() async {
    var settings = GlobalSettings.default
    settings.githubIntegrationEnabled = false
    settings.mergedWorktreeAction = .archive
    settings.moveNotifiedWorktreeToTop = true
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }

    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.receive(\.repositories.setGithubIntegrationEnabled) {
      $0.repositories.githubIntegrationAvailability = .disabled
    }
    await store.receive(\.repositories.setMergedWorktreeAction) {
      $0.repositories.mergedWorktreeAction = .archive
    }
    await store.receive(\.repositories.setMoveNotifiedWorktreeToTop) {
      $0.repositories.moveNotifiedWorktreeToTop = true
    }
    await store.receive(\.repositories.openActionSettingsChanged)
    await store.receive(\.repositories.setAutoDeleteArchivedWorktreesAfterDays)
    await store.receive(\.updates.applySettings) {
      $0.updates.didConfigureUpdates = true
    }
    await store.finish()
  }

  @Test(.dependencies) func togglingAgentPresenceBadgesFansOutClearedSnapshots() async {
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
    var repositoriesState = RepositoriesFeature.State(reconciledRepositories: [repository])
    let surfaceID = UUID()
    let idleSurfaceID = UUID()
    let agent = AgentPresenceFeature.AgentInstance(agent: .claude, activity: .busy)
    repositoriesState.sidebarItems[id: worktree.id]?.surfaceIDs = [surfaceID, idleSurfaceID]
    repositoriesState.sidebarItems[id: worktree.id]?.agentSnapshot.agents = [agent]
    repositoriesState.sidebarItems[id: worktree.id]?.agentSnapshot.isWorking = true
    var appState = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    appState.agentPresence.bySurface[surfaceID] = [.claude]
    appState.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    ] = AgentPresenceFeature.PresenceRecord(activity: .busy, pids: [42])
    let store = TestStore(initialState: appState) {
      AppFeature()
    }
    store.exhaustivity = .off

    var settings = GlobalSettings.default
    settings.agentPresenceBadgesEnabled = false

    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.receive(
      \.repositories.sidebarItems[id: worktree.id].agentSnapshotChanged
    ) {
      $0.repositories.sidebarItems[id: worktree.id]?.agentSnapshot.agents = []
      $0.repositories.sidebarItems[id: worktree.id]?.agentSnapshot.isWorking = true
    }
    await store.finish()
    #expect(store.state.lastKnownAgentPresenceBadgesEnabled == false)

    settings.agentPresenceBadgesEnabled = true
    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.receive(
      \.repositories.sidebarItems[id: worktree.id].agentSnapshotChanged
    ) {
      $0.repositories.sidebarItems[id: worktree.id]?.agentSnapshot.agents = [agent]
    }
    await store.finish()
    #expect(store.state.lastKnownAgentPresenceBadgesEnabled == true)
  }

  @Test(.dependencies) func agentPresenceDeltaFansOutOnlyToTabsContainingChangedSurfaces() async {
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
    let changedSurfaceID = UUID()
    let siblingSurfaceID = UUID()
    var repositoriesState = RepositoriesFeature.State(reconciledRepositories: [repository])
    repositoriesState.sidebarItems[id: worktree.id]?.surfaceIDs = [
      changedSurfaceID,
      siblingSurfaceID,
    ]
    var appState = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    appState.agentPresence.bySurface[changedSurfaceID] = [.claude]
    appState.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: changedSurfaceID)
    ] = AgentPresenceFeature.PresenceRecord(activity: .busy, pids: [42])
    let clock = TestClock()
    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.sidebarStructureAutoRecompute = false
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
      $0.terminalClient.send = { _ in }
    }
    let agent = AgentPresenceFeature.AgentInstance(agent: .claude, activity: .busy)

    await store.send(.agentPresence(.delegate(.surfacesChanged([changedSurfaceID]))))
    await store.receive(
      \.repositories.sidebarItems[id: worktree.id].agentSnapshotChanged
    ) {
      $0.repositories.sidebarItems[id: worktree.id]?.agentSnapshot = .init(
        agents: [agent],
        isWorking: true
      )
    }
    await clock.advance(by: .seconds(1))
    await store.finish()
  }

  @Test(.dependencies) func agentPresenceDeltaWritesTheContentsTabChrome() async {
    let surfaceID = UUID()
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: ContentID(rawValue: surfaceID))
    #expect(runtime.provision(content, at: .fallback))
    var appState = AppFeature.State(
      repositories: RepositoriesFeature.State(),
      settings: SettingsFeature.State()
    )
    appState.agentPresence.bySurface[surfaceID] = [.claude]
    appState.agentPresence.records[
      AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
    ] = AgentPresenceFeature.PresenceRecord(activity: .busy, pids: [42])
    let clock = TestClock()
    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.contentRuntime = runtime
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
      $0.terminalClient.send = { _ in }
    }

    await store.send(.agentPresence(.delegate(.surfacesChanged([surfaceID]))))
    await clock.advance(by: .seconds(1))
    await store.finish()
    #expect(content.terminalChrome.agents == [.init(agent: .claude, activity: .busy)])
    #expect(content.terminalChrome.isWorking)
  }

  @Test(.dependencies) func agentPresenceDeltaClearsTheChromeWhenTheLastAgentLeaves() async {
    let surfaceID = UUID()
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: ContentID(rawValue: surfaceID))
    #expect(runtime.provision(content, at: .fallback))
    // Stale badge from an earlier snapshot; the empty delta must clear it.
    content.terminalChrome.agents = [.init(agent: .claude, activity: .busy)]
    content.terminalChrome.isWorking = true
    let clock = TestClock()
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.contentRuntime = runtime
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
      $0.terminalClient.send = { _ in }
    }

    await store.send(.agentPresence(.delegate(.surfacesChanged([surfaceID]))))
    await clock.advance(by: .seconds(1))
    await store.finish()
    #expect(content.terminalChrome.agents.isEmpty)
    #expect(!content.terminalChrome.isWorking)
  }

  @Test(.dependencies) func togglingHibernationFlagFansOutToTerminalClient() async {
    let sentEnabled = LockIsolated<[Bool]>([])
    var appState = AppFeature.State(
      repositories: RepositoriesFeature.State(),
      settings: SettingsFeature.State()
    )
    appState.lastKnownTerminalHibernationEnabled = true

    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        guard case .setTerminalHibernationEnabled(let enabled) = command else { return }
        sentEnabled.withValue { $0.append(enabled) }
      }
    }
    store.exhaustivity = .off

    var settings = GlobalSettings.default
    settings.terminalHibernationEnabled = false

    // The flip fires the command once with the new value and tracks the flag.
    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.finish()
    #expect(sentEnabled.value == [false])
    #expect(store.state.lastKnownTerminalHibernationEnabled == false)

    // A settingsChanged that does not flip hibernation emits no further command.
    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.finish()
    #expect(sentEnabled.value == [false])
    #expect(store.state.lastKnownTerminalHibernationEnabled == false)
  }

  @Test(.dependencies) func settingsChangedFansOutAutomaticRefreshToWatcher() async {
    let commands = LockIsolated<[WorktreeInfoWatcherClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.worktreeInfoWatcher.send = { command in
        commands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    var settings = GlobalSettings.default
    settings.automaticRepositoryRefreshEnabled = false

    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.finish()
    #expect(commands.value.contains(.setAutomaticRefreshEnabled(false)))
  }

  @Test(.dependencies) func focusingASurfaceClearsTheStatesParkedOnIt() async {
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
    var repositoriesState = RepositoriesFeature.State(reconciledRepositories: [repository])
    let focused = UUID()
    let background = UUID()
    repositoriesState.sidebarItems[id: worktree.id]?.surfaceIDs = [focused, background]

    var appState = AppFeature.State(
      repositories: repositoriesState,
      settings: SettingsFeature.State()
    )
    for surfaceID in [focused, background] {
      appState.agentPresence.bySurface[surfaceID] = [.claude]
      appState.agentPresence.records[
        AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: surfaceID)
      ] = AgentPresenceFeature.PresenceRecord(activity: .error, pids: [42])
    }

    let store = TestStore(initialState: appState) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.terminalEvent(.focusChanged(worktreeID: worktree.id, surfaceID: focused)))
    await store.skipReceivedActions()
    await store.finish()

    // Only the surface the user is actually looking at clears; a broken session in
    // another split of the same worktree keeps its warning.
    #expect(!store.state.agentPresence.hasError(in: [focused]))
    #expect(store.state.agentPresence.hasError(in: [background]))
  }
}
