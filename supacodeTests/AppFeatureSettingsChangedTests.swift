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
    settings.moveNotifiedWorktreeToTop = false
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
      $0.repositories.moveNotifiedWorktreeToTop = false
    }
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
    let agent = AgentPresenceFeature.AgentInstance(agent: .claude, activity: .busy)
    repositoriesState.sidebarItems[id: worktree.id]?.surfaceIDs = [surfaceID]
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
