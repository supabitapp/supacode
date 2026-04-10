import ComposableArchitecture
import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@MainActor
struct SettingsFeatureAgentHookTests {
  @Test(.dependencies) func agentHookCheckedSetsInstalled() async {
    var state = SettingsFeature.State()
    state.claudeProgressState = .checking

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.agentHookChecked(.claudeProgress, installed: true)) {
      $0.claudeProgressState = .installed
    }
  }

  @Test(.dependencies) func agentHookCheckedSetsNotInstalled() async {
    var state = SettingsFeature.State()
    state.codexNotificationsState = .checking

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.agentHookChecked(.codexNotifications, installed: false)) {
      $0.codexNotificationsState = .notInstalled
    }
  }

  @Test(.dependencies) func installTransitionsToInstalledOnSuccess() async {
    var state = SettingsFeature.State()
    state.claudeProgressState = .notInstalled

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[ClaudeSettingsClient.self].installProgress = {}
    }

    await store.send(.agentHookInstallTapped(.claudeProgress)) {
      $0.claudeProgressState = .installing
    }
    await store.receive(\.agentHookActionCompleted) {
      $0.claudeProgressState = .installed
    }
  }

  @Test(.dependencies) func installTransitionsToFailedOnError() async {
    var state = SettingsFeature.State()
    state.codexProgressState = .notInstalled

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[CodexSettingsClient.self].installProgress = {
        throw CodexSettingsInstallerError.codexUnavailable
      }
    }

    await store.send(.agentHookInstallTapped(.codexProgress)) {
      $0.codexProgressState = .installing
    }
    await store.receive(\.agentHookActionCompleted) {
      $0.codexProgressState = .failed(CodexSettingsInstallerError.codexUnavailable.localizedDescription)
    }
  }

  @Test(.dependencies) func installWhileLoadingIsNoOp() async {
    var state = SettingsFeature.State()
    state.claudeProgressState = .installing

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.agentHookInstallTapped(.claudeProgress))
    // No state change, no effect — the guard short-circuits.
  }

  @Test(.dependencies) func uninstallTransitionsToNotInstalledOnSuccess() async {
    var state = SettingsFeature.State()
    state.claudeNotificationsState = .installed

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[ClaudeSettingsClient.self].uninstallNotifications = {}
    }

    await store.send(.agentHookUninstallTapped(.claudeNotifications)) {
      $0.claudeNotificationsState = .uninstalling
    }
    await store.receive(\.agentHookActionCompleted) {
      $0.claudeNotificationsState = .notInstalled
    }
  }

  @Test(.dependencies) func uninstallWhileLoadingIsNoOp() async {
    var state = SettingsFeature.State()
    state.codexNotificationsState = .checking

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.agentHookUninstallTapped(.codexNotifications))
  }

  @Test(.dependencies) func taskStartsInstalledChecksInParallel() async {
    let startedChecks = LockIsolated<Set<String>>([])
    let continuations = LockIsolated<[CheckedContinuation<Void, Never>]>([])

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0[CLIInstallerClient.self].checkInstalled = { false }
      $0[CLISkillClient.self].checkInstalled = { _ in false }
      $0[ClaudeSettingsClient.self].checkInstalled = { progress in
        let key = progress ? "claudeProgress" : "claudeNotifications"
        _ = startedChecks.withValue { $0.insert(key) }
        await withCheckedContinuation { continuation in
          continuations.withValue { $0.append(continuation) }
        }
        return progress
      }
      $0[CodexSettingsClient.self].checkInstalled = { progress in
        let key = progress ? "codexProgress" : "codexNotifications"
        _ = startedChecks.withValue { $0.insert(key) }
        await withCheckedContinuation { continuation in
          continuations.withValue { $0.append(continuation) }
        }
        return progress
      }
    }

    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.task)
    await store.receive(\.settingsLoaded)

    // CLI/skill/hook checks run in parallel via `.merge`.
    // CLI/skill mocks return immediately; hook checks block on continuations.
    // Wait for all four hook checks to start.
    await eventually {
      startedChecks.value.count == 4
    }

    continuations.withValue { continuations in
      for continuation in continuations {
        continuation.resume()
      }
      continuations.removeAll()
    }

    await store.skipReceivedActions()
  }

  @Test(.dependencies) func taskChecksAllFourHookSlotsOnStartup() async {
    let checkedSlots = LockIsolated<[String]>([])

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0[CLIInstallerClient.self].checkInstalled = { false }
      $0[CLISkillClient.self].checkInstalled = { _ in false }
      $0[ClaudeSettingsClient.self].checkInstalled = { progress in
        checkedSlots.withValue { $0.append(progress ? "claudeProgress" : "claudeNotifications") }
        return progress
      }
      $0[CodexSettingsClient.self].checkInstalled = { progress in
        checkedSlots.withValue { $0.append(progress ? "codexProgress" : "codexNotifications") }
        return progress
      }
    }

    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.task)
    await store.receive(\.settingsLoaded)
    await store.skipReceivedActions()

    #expect(
      Set(checkedSlots.value) == [
        "claudeProgress",
        "claudeNotifications",
        "codexProgress",
        "codexNotifications",
      ])
  }

  private func eventually(
    maxYields: Int = 100,
    _ predicate: () -> Bool
  ) async {
    for _ in 0..<maxYields {
      if predicate() { return }
      await Task.yield()
    }
    Issue.record("Condition was not satisfied before timeout")
  }

  // MARK: - CLI install actions.

  @Test(.dependencies) func cliInstallCheckedSetsInstalled() async {
    var state = SettingsFeature.State()
    state.cliInstallState = .checking

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.cliInstallChecked(installed: true)) {
      $0.cliInstallState = .installed
    }
  }

  @Test(.dependencies) func cliInstallCheckedSetsNotInstalled() async {
    var state = SettingsFeature.State()
    state.cliInstallState = .checking

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.cliInstallChecked(installed: false)) {
      $0.cliInstallState = .notInstalled
    }
  }

  @Test(.dependencies) func cliInstallTransitionsToInstalledOnSuccess() async {
    var state = SettingsFeature.State()
    state.cliInstallState = .notInstalled

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[CLIInstallerClient.self].install = {}
    }

    await store.send(.cliInstallTapped) {
      $0.cliInstallState = .installing
    }
    await store.receive(\.cliInstallCompleted) {
      $0.cliInstallState = .installed
    }
  }

  @Test(.dependencies) func cliInstallTransitionsToFailedOnError() async {
    var state = SettingsFeature.State()
    state.cliInstallState = .notInstalled

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[CLIInstallerClient.self].install = {
        throw CLIInstallerError.bundledBinaryNotFound
      }
    }

    await store.send(.cliInstallTapped) {
      $0.cliInstallState = .installing
    }
    await store.receive(\.cliInstallCompleted) {
      $0.cliInstallState = .failed(CLIInstallerError.bundledBinaryNotFound.localizedDescription)
    }
  }

  @Test(.dependencies) func cliInstallCancelledResetsToNotInstalled() async {
    var state = SettingsFeature.State()
    state.cliInstallState = .notInstalled

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[CLIInstallerClient.self].install = {
        throw CLIInstallerError.cancelled
      }
    }

    await store.send(.cliInstallTapped) {
      $0.cliInstallState = .installing
    }
    await store.receive(\.cliInstallCompleted) {
      $0.cliInstallState = .notInstalled
    }
  }

  @Test(.dependencies) func cliInstallWhileLoadingIsNoOp() async {
    var state = SettingsFeature.State()
    state.cliInstallState = .installing

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.cliInstallTapped)
  }

  @Test(.dependencies) func cliUninstallTransitionsToNotInstalledOnSuccess() async {
    var state = SettingsFeature.State()
    state.cliInstallState = .installed

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[CLIInstallerClient.self].uninstall = {}
    }

    await store.send(.cliUninstallTapped) {
      $0.cliInstallState = .uninstalling
    }
    await store.receive(\.cliInstallCompleted) {
      $0.cliInstallState = .notInstalled
    }
  }

  @Test(.dependencies) func cliUninstallWhileLoadingIsNoOp() async {
    var state = SettingsFeature.State()
    state.cliInstallState = .uninstalling

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.cliUninstallTapped)
  }

  @Test(.dependencies) func cliUninstallCancelledRestoresToInstalled() async {
    var state = SettingsFeature.State()
    state.cliInstallState = .installed

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[CLIInstallerClient.self].uninstall = {
        throw CLIInstallerError.cancelled
      }
    }

    await store.send(.cliUninstallTapped) {
      $0.cliInstallState = .uninstalling
    }
    await store.receive(\.cliInstallCompleted) {
      $0.cliInstallState = .installed
    }
  }

  // MARK: - CLI skill install actions.

  @Test(.dependencies) func cliSkillCheckedSetsInstalled() async {
    var state = SettingsFeature.State()
    state.claudeSkillState = .checking

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.cliSkillChecked(agent: .claude, installed: true)) {
      $0.claudeSkillState = .installed
    }
  }

  @Test(.dependencies) func cliSkillInstallTransitionsToInstalledOnSuccess() async {
    var state = SettingsFeature.State()
    state.codexSkillState = .notInstalled

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[CLISkillClient.self].install = { _ in }
    }

    await store.send(.cliSkillInstallTapped(.codex)) {
      $0.codexSkillState = .installing
    }
    await store.receive(\.cliSkillCompleted) {
      $0.codexSkillState = .installed
    }
  }

  @Test(.dependencies) func cliSkillInstallTransitionsToFailedOnError() async {
    var state = SettingsFeature.State()
    state.claudeSkillState = .notInstalled
    let errorMessage = "Write failed"

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[CLISkillClient.self].install = { _ in
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
      }
    }

    await store.send(.cliSkillInstallTapped(.claude)) {
      $0.claudeSkillState = .installing
    }
    await store.receive(\.cliSkillCompleted) {
      $0.claudeSkillState = .failed(errorMessage)
    }
  }

  @Test(.dependencies) func cliSkillInstallWhileLoadingIsNoOp() async {
    var state = SettingsFeature.State()
    state.codexSkillState = .installing

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.cliSkillInstallTapped(.codex))
  }

  @Test(.dependencies) func cliSkillUninstallTransitionsToNotInstalledOnSuccess() async {
    var state = SettingsFeature.State()
    state.claudeSkillState = .installed

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[CLISkillClient.self].uninstall = { _ in }
    }

    await store.send(.cliSkillUninstallTapped(.claude)) {
      $0.claudeSkillState = .uninstalling
    }
    await store.receive(\.cliSkillCompleted) {
      $0.claudeSkillState = .notInstalled
    }
  }

  @Test(.dependencies) func cliSkillUninstallWhileLoadingIsNoOp() async {
    var state = SettingsFeature.State()
    state.claudeSkillState = .uninstalling

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.cliSkillUninstallTapped(.claude))
  }
}
