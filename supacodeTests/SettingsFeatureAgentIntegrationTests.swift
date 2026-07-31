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
    state.agentInstallSheetPresented = true

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in throw IntegrationTestError.boom }
    }

    await store.send(.agentIntegrationInstallTapped(.codex)) {
      $0.agentIntegrationStates[.codex] = .installing
    }
    // Installing a not-yet-present agent from the open modal produces a
    // transient (modal) error.
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.codex] = .failedTransient("boom")
    }
  }

  @Test(.dependencies) func retryingPersistentFailureStaysPersistent() async {
    // A persistent `.failed` row (from a failed uninstall / update) is retried
    // via its main-list Install button; another failure must NOT demote it to a
    // modal-only `.failedTransient`, which would make it vanish.
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.claude] = .failed("earlier")

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in throw IntegrationTestError.boom }
    }

    await store.send(.agentIntegrationInstallTapped(.claude)) {
      $0.agentIntegrationStates[.claude] = .installing
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.claude] = .failed("boom")
    }
  }

  @Test(.dependencies) func transientFailureWithModalClosedReprobesInsteadOfStranding() async {
    // If the install modal is dismissed while a fresh install is in flight and
    // that install then fails, the transient error has nowhere to show, so the
    // row is re-probed rather than stranded as an invisible `.failedTransient`.
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.grok] = .installing
    state.agentInstallSheetPresented = false

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].state = { _ in .notInstalled }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.agentIntegrationCompleted(.grok, .failure(IntegrationTestError.boom), failureIsTransient: true)) {
      $0.agentIntegrationStates[.grok] = .checking
    }
    await store.skipReceivedActions()
    #expect(store.state.agentIntegrationStates[.grok] == .ready(.notInstalled))
  }

  @Test(.dependencies) func persistentFailureOfLastModalCandidateDismissesSheet() async {
    // The sheet's last candidate is an outdated agent being updated; a
    // persistent failure drops it out of the candidate set, so the now-empty
    // sheet must dismiss.
    var state = SettingsFeature.State()
    for agent in SkillAgent.allCases { state.agentIntegrationStates[agent] = .ready(.installed) }
    state.agentIntegrationStates[.grok] = .installing
    state.agentInstallSheetPresented = true

    let store = TestStore(initialState: state) { SettingsFeature() }

    let completion = SettingsFeature.Action.agentIntegrationCompleted(
      .grok, .failure(IntegrationTestError.boom), failureIsTransient: false)
    await store.send(completion) {
      $0.agentIntegrationStates[.grok] = .failed("boom")
      $0.agentInstallSheetPresented = false
    }
  }

  @Test(.dependencies) func updateFailureFromOutdatedIsPersistent() async {
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.claude] = .ready(.outdated)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in throw IntegrationTestError.boom }
    }

    await store.send(.agentIntegrationInstallTapped(.claude)) {
      $0.agentIntegrationStates[.claude] = .installing
    }
    // Updating an already-present (outdated) integration surfaces failures as a
    // persistent main-list error, not a transient modal one.
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.claude] = .failed("boom")
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

  @Test(.dependencies) func outdatedStateAlwaysAutoFiresInstall() async {
    var state = SettingsFeature.State()
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

  @Test(.dependencies) func checkedActionPreservesFailedStateAndDoesNotAutoRetry() async {
    // `.failed` must survive a periodic refresh so the error stays visible
    // AND the auto re-install can't loop on a persistent failure (read-only
    // file, malformed JSON, etc.). Without the guard, the shared
    // `AgentIntegrationCancelID` also lets the re-install cancel a manual
    // remediation mid-flight.
    let installRan = LockIsolated(false)
    var state = SettingsFeature.State()
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
    // (b) the auto re-install would dispatch `.agentIntegrationInstallTapped`,
    // whose `.cancellable` (same id, cancelInFlight: true) cancels the manual
    // uninstall mid-flight, leaving the file half-pruned.
    let installRan = LockIsolated(false)
    var state = SettingsFeature.State()
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

  @Test(.dependencies) func installSheetOpenIsNoOpWhenEverythingInstalled() async {
    var state = SettingsFeature.State()
    for agent in SkillAgent.allCases { state.agentIntegrationStates[agent] = .ready(.installed) }

    let store = TestStore(initialState: state) { SettingsFeature() }

    // No installable agents → the guard suppresses presentation entirely.
    await store.send(.agentInstallSheetOpenTapped)
  }

  @Test(.dependencies) func installSheetOpensWhenAnAgentIsUninstalled() async {
    var state = SettingsFeature.State()
    for agent in SkillAgent.allCases { state.agentIntegrationStates[agent] = .ready(.installed) }
    state.agentIntegrationStates[.grok] = .ready(.notInstalled)

    let store = TestStore(initialState: state) { SettingsFeature() }

    await store.send(.agentInstallSheetOpenTapped) {
      $0.agentInstallSheetPresented = true
    }
  }

  @Test(.dependencies) func installSheetDismissesWhenLastAgentSettlesInstalled() async {
    var state = SettingsFeature.State()
    for agent in SkillAgent.allCases { state.agentIntegrationStates[agent] = .ready(.installed) }
    state.agentIntegrationStates[.grok] = .ready(.notInstalled)
    state.agentInstallSheetPresented = true

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in }
      $0[AgentIntegrationClient.self].state = { _ in .installed }
    }

    await store.send(.agentIntegrationInstallTapped(.grok)) {
      $0.agentIntegrationStates[.grok] = .installing
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.grok] = .ready(.installed)
      $0.agentInstallSheetPresented = false
    }
  }

  @Test(.dependencies) func installSheetStaysOpenWhileOtherAgentsRemain() async {
    var state = SettingsFeature.State()
    for agent in SkillAgent.allCases { state.agentIntegrationStates[agent] = .ready(.installed) }
    state.agentIntegrationStates[.grok] = .ready(.notInstalled)
    state.agentIntegrationStates[.kiro] = .ready(.notInstalled)
    state.agentInstallSheetPresented = true

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in }
      $0[AgentIntegrationClient.self].state = { _ in .installed }
    }

    await store.send(.agentIntegrationInstallTapped(.grok)) {
      $0.agentIntegrationStates[.grok] = .installing
    }
    // `.kiro` is still not installed, so the sheet stays presented.
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.grok] = .ready(.installed)
    }
  }

  @Test(.dependencies) func installSheetStaysOpenWhenLastAgentInstallFails() async {
    var state = SettingsFeature.State()
    for agent in SkillAgent.allCases { state.agentIntegrationStates[agent] = .ready(.installed) }
    state.agentIntegrationStates[.grok] = .ready(.notInstalled)
    state.agentInstallSheetPresented = true

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in throw IntegrationTestError.boom }
    }

    await store.send(.agentIntegrationInstallTapped(.grok)) {
      $0.agentIntegrationStates[.grok] = .installing
    }
    // A transient install error stays in the modal, so the sheet must not dismiss.
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.grok] = .failedTransient("boom")
    }
  }

  @Test(.dependencies) func installSheetStaysOpenWhileASiblingInstallIsInFlight() async {
    var state = SettingsFeature.State()
    for agent in SkillAgent.allCases { state.agentIntegrationStates[agent] = .ready(.installed) }
    state.agentIntegrationStates[.grok] = .installing
    state.agentIntegrationStates[.kiro] = .installing
    state.agentInstallSheetPresented = true

    let store = TestStore(initialState: state) { SettingsFeature() }

    // `uninstalledAgents` is already empty, but `.kiro` is still installing, so
    // the dismiss must key off the wider sheet set and keep the sheet open.
    await store.send(.agentIntegrationCompleted(.grok, .success(.installed), failureIsTransient: false)) {
      $0.agentIntegrationStates[.grok] = .ready(.installed)
    }
  }

  @Test(.dependencies) func installSheetStaysOpenWhenInstallResolvesOutdated() async {
    var state = SettingsFeature.State()
    for agent in SkillAgent.allCases { state.agentIntegrationStates[agent] = .ready(.installed) }
    state.agentIntegrationStates[.grok] = .ready(.notInstalled)
    state.agentInstallSheetPresented = true

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in }
      $0[AgentIntegrationClient.self].state = { _ in .outdated }
    }

    await store.send(.agentIntegrationInstallTapped(.grok)) {
      $0.agentIntegrationStates[.grok] = .installing
    }
    // A non-converged install (still outdated) stays in the modal instead of
    // dismissing as a false success.
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.grok] = .ready(.outdated)
    }
  }

  @Test(.dependencies) func installSheetDismissesWhenRefreshResolvesLastAgentInstalled() async {
    var state = SettingsFeature.State()
    for agent in SkillAgent.allCases { state.agentIntegrationStates[agent] = .ready(.installed) }
    state.agentIntegrationStates[.grok] = .ready(.notInstalled)
    state.agentInstallSheetPresented = true

    let store = TestStore(initialState: state) { SettingsFeature() }

    // Grok is installed externally; a scene-activation refresh observes it and
    // must empty-and-dismiss the sheet, not only the completed-install path.
    await store.send(.agentIntegrationChecked(.grok, .installed)) {
      $0.agentIntegrationStates[.grok] = .ready(.installed)
      $0.agentInstallSheetPresented = false
    }
  }

  @Test(.dependencies) func outdatedRecheckDoesNotReArmInstallWhenAlreadyOutdated() async {
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.claude] = .ready(.outdated)

    let store = TestStore(initialState: state) { SettingsFeature() }

    // A prior re-install already left it outdated, so a re-check must not
    // re-fire the install (no `.agentIntegrationInstallTapped` is received).
    await store.send(.agentIntegrationChecked(.claude, .outdated))
  }

  @Test(.dependencies) func setAgentInstallSheetPresentedDrivesPresentation() async {
    let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }

    await store.send(.setAgentInstallSheetPresented(true)) {
      $0.agentInstallSheetPresented = true
    }
    await store.send(.setAgentInstallSheetPresented(false)) {
      $0.agentInstallSheetPresented = false
    }
  }

  @Test(.dependencies) func dismissingSheetClearsTransientButNotPersistentErrors() async {
    var state = SettingsFeature.State()
    for agent in SkillAgent.allCases { state.agentIntegrationStates[agent] = .ready(.installed) }
    state.agentIntegrationStates[.grok] = .failedTransient("boom")
    state.agentIntegrationStates[.pi] = .failed("nope")
    state.agentInstallSheetPresented = true

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].state = { _ in .installed }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // The transient row drops to `.checking` and a re-probe is dispatched; the
    // persistent uninstall error is left untouched.
    await store.send(.setAgentInstallSheetPresented(false)) {
      $0.agentInstallSheetPresented = false
      $0.agentIntegrationStates[.grok] = .checking
    }
    await store.skipReceivedActions()
    // The re-probe resolves the cleared row (nothing stranded at `.checking`)
    // while the persistent error is left intact.
    #expect(store.state.agentIntegrationStates[.grok] == .ready(.installed))
    #expect(store.state.agentIntegrationStates[.pi] == .failed("nope"))
  }

  @Test(.dependencies) func installSheetOpenIsNoOpWhenNothingIsCleanlyUninstalled() async {
    var state = SettingsFeature.State()
    for agent in SkillAgent.allCases { state.agentIntegrationStates[agent] = .ready(.installed) }
    state.agentIntegrationStates[.grok] = .failed("boom")

    let store = TestStore(initialState: state) { SettingsFeature() }

    // `uninstalledAgents` is empty (grok is failed, not not-installed), so the
    // open guard suppresses presentation even though the sheet set is non-empty.
    await store.send(.agentInstallSheetOpenTapped)
  }

  @Test(.dependencies) func agentPartitioningSplitsInstalledFromNotInstalled() {
    var state = SettingsFeature.State()
    state.agentIntegrationStates = [
      .claude: .ready(.installed),
      .codex: .ready(.outdated),
      .grok: .ready(.notInstalled),
      .kiro: .installing,
      .omp: .failedTransient("boom"),  // install error: modal-only.
      .pi: .failed("nope"),  // uninstall / update error: main list.
      // Remaining agents stay absent (still checking).
    ]

    // Both failure kinds surface their message under the row.
    #expect(state.agentIntegrationStates[.omp]?.errorMessage == "boom")
    #expect(state.agentIntegrationStates[.pi]?.errorMessage == "nope")
    // Only cleanly not-installed agents feed the collapsed prompt.
    #expect(state.uninstalledAgents == [.grok])
    // The modal holds not-installed, mid-install, transiently-errored, and
    // outdated agents, sorted by display name (persistent `pi` is excluded).
    #expect(state.agentInstallSheetAgents == [.codex, .grok, .kiro, .omp])
    // The main list omits not-installed (`grok`) and transiently-errored (`omp`)
    // agents but keeps the persistent error (`pi`).
    #expect(
      state.mainListAgentRows == [
        .claude, .codex, .copilot, .antigravity, .hermes, .kimi, .kiro, .opencode, .pi,
      ]
    )
    // A transient error is modal-only; a persistent error is main-list-only; a
    // mid-install agent shows in both surfaces.
    #expect(!state.mainListAgentRows.contains(.omp) && state.agentInstallSheetAgents.contains(.omp))
    #expect(state.mainListAgentRows.contains(.pi) && !state.agentInstallSheetAgents.contains(.pi))
    #expect(state.mainListAgentRows.contains(.kiro) && state.agentInstallSheetAgents.contains(.kiro))
  }
}

private enum IntegrationTestError: LocalizedError {
  case boom
  var errorDescription: String? { "boom" }
}
