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

  @Test(.dependencies) func outdatedStateAutoFiresInstallWhenAutoUpdateEnabled() async {
    var state = SettingsFeature.State()
    state.autoUpdateAgentIntegrationsEnabled = true
    state.agentIntegrationStates[.claude] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in }
      $0[AgentIntegrationClient.self].state = { _ in .installed }
    }

    await store.send(.agentIntegrationChecked(.claude, .outdated)) {
      $0.agentIntegrationStates[.claude] = .ready(.outdated)
    }
    await store.receive(\.agentIntegrationInstallTapped) {
      $0.agentIntegrationStates[.claude] = .installing
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.claude] = .ready(.installed)
    }
  }

  @Test(.dependencies) func outdatedStateDoesNothingWhenAutoUpdateDisabled() async {
    var state = SettingsFeature.State()
    state.autoUpdateAgentIntegrationsEnabled = false
    state.agentIntegrationStates[.codex] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].state = { _ in .outdated }
    }

    await store.send(.agentIntegrationChecked(.codex, .outdated)) {
      $0.agentIntegrationStates[.codex] = .ready(.outdated)
    }
  }

  @Test(.dependencies) func checkedActionPreservesFailedStateAndDoesNotAutoRetry() async {
    // `.failed` must survive a periodic refresh so the error stays
    // visible AND auto-update can't loop on a persistent failure
    // (read-only file, malformed JSON, etc.). Without the guard, the
    // shared `AgentIntegrationCancelID` also lets auto-update cancel a
    // manual remediation mid-flight.
    let installRan = LockIsolated(false)
    var state = SettingsFeature.State()
    state.autoUpdateAgentIntegrationsEnabled = true
    state.agentIntegrationStates[.claude] = .failed("disk full")

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in installRan.setValue(true) }
    }

    await store.send(.agentIntegrationChecked(.claude, .outdated))
    #expect(!installRan.value)
    #expect(state.agentIntegrationStates[.claude] == .failed("disk full"))
  }

  @Test(.dependencies) func checkedActionDoesNotClobberInFlightUninstall() async {
    // A periodic `refreshAgentIntegrationStates` (e.g. scene activation)
    // mid-uninstall must not stomp the `.uninstalling` UI state. Stomping
    // would (a) flip the row back to "Installed" or "Outdated", and worse,
    // (b) the auto-update branch would dispatch
    // `.agentIntegrationInstallTapped`, whose `.cancellable` (same id,
    // cancelInFlight: true) cancels the manual uninstall mid-flight,
    // leaving the file half-pruned.
    let installRan = LockIsolated(false)
    var state = SettingsFeature.State()
    state.autoUpdateAgentIntegrationsEnabled = true
    state.agentIntegrationStates[.claude] = .uninstalling

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in installRan.setValue(true) }
    }

    await store.send(.agentIntegrationChecked(.claude, .outdated))
    #expect(!installRan.value)
  }

  @Test(.dependencies) func tappingInstallTwiceCancelsTheFirstEffect() async {
    // Suspend until cancelled — proves `.cancellable(cancelInFlight:)`
    // without a wall-clock wait that would slow CI by 5s on success.
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.claude] = .ready(.notInstalled)

    let secondInstallStarted = LockIsolated(false)
    let firstReachedFinish = LockIsolated(false)
    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in
        if secondInstallStarted.value { return }
        let stored = LockIsolated<CheckedContinuation<Void, Error>?>(nil)
        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            stored.withValue { slot in
              if Task.isCancelled {
                cont.resume(throwing: CancellationError())
              } else {
                slot = cont
              }
            }
          }
        } onCancel: {
          stored.withValue { slot in
            slot?.resume(throwing: CancellationError())
            slot = nil
          }
        }
        firstReachedFinish.setValue(true)
      }
      $0[AgentIntegrationClient.self].state = { _ in .installed }
    }

    await store.send(.agentIntegrationInstallTapped(.claude)) {
      $0.agentIntegrationStates[.claude] = .installing
    }
    secondInstallStarted.setValue(true)
    await store.send(.agentIntegrationInstallTapped(.claude))
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.claude] = .ready(.installed)
    }

    #expect(!firstReachedFinish.value)
  }
}

private enum IntegrationTestError: LocalizedError {
  case boom
  var errorDescription: String? { "boom" }
}
