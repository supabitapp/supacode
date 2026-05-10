import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import SupacodeSettingsFeature
import SupacodeSettingsShared
import Testing

@MainActor
struct SettingsFeatureAgentIntegrationTests {
  @Test(.dependencies) func installTappedTransitionsThroughInstallingToReady() async {
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.claude] = .ready(.notInstalled)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in }
      $0[AgentIntegrationClient.self].state = { _ in .installed }
    }

    await store.send(.agentIntegrationInstallTapped(.claude)) {
      $0.agentIntegrationStates[.claude] = .installing
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.claude] = .ready(.installed)
    }
  }

  @Test(.dependencies) func installFailureSurfacesErrorMessage() async {
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.codex] = .ready(.notInstalled)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in throw IntegrationTestError.boom }
    }

    await store.send(.agentIntegrationInstallTapped(.codex)) {
      $0.agentIntegrationStates[.codex] = .installing
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.codex] = .failed("boom")
    }
  }

  @Test(.dependencies) func uninstallTappedTransitionsThroughUninstallingToReady() async {
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.kiro] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].uninstall = { _ in }
      $0[AgentIntegrationClient.self].state = { _ in .notInstalled }
    }

    await store.send(.agentIntegrationUninstallTapped(.kiro)) {
      $0.agentIntegrationStates[.kiro] = .uninstalling
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.kiro] = .ready(.notInstalled)
    }
  }

  @Test(.dependencies) func uninstallFailureSurfacesErrorMessage() async {
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.pi] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].uninstall = { _ in throw IntegrationTestError.boom }
    }

    await store.send(.agentIntegrationUninstallTapped(.pi)) {
      $0.agentIntegrationStates[.pi] = .uninstalling
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.pi] = .failed("boom")
    }
  }

  @Test(.dependencies) func taskChecksAllAgentsOnStartup() async {
    let checked = LockIsolated<Set<SkillAgent>>([])

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0[CLIInstallerClient.self].checkInstalled = { false }
      $0[AgentIntegrationClient.self].state = { agent in
        checked.withValue { $0.insert(agent) }
        return .notInstalled
      }
    }

    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.task)
    await store.skipReceivedActions()

    #expect(checked.value == Set(SkillAgent.allCases))
  }
}

private enum IntegrationTestError: LocalizedError {
  case boom
  var errorDescription: String? { "boom" }
}
