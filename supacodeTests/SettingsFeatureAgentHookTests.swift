import ComposableArchitecture
import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
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
      $0[KiroSettingsClient.self].checkInstalled = { progress in
        let key = progress ? "kiroProgress" : "kiroNotifications"
        _ = startedChecks.withValue { $0.insert(key) }
        await withCheckedContinuation { continuation in
          continuations.withValue { $0.append(continuation) }
        }
        return progress
      }
      $0[PiSettingsClient.self].checkInstalled = {
        _ = startedChecks.withValue { $0.insert("piHooks") }
        await withCheckedContinuation { continuation in
          continuations.withValue { $0.append(continuation) }
        }
        return false
      }
    }

    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.task)
    await store.receive(\.settingsLoaded)

    // CLI/skill/hook checks run in parallel via `.merge`.
    // CLI/skill mocks return immediately; hook checks block on continuations.
    // Wait for all seven hook checks to start.
    await eventually {
      startedChecks.value.count == 7
    }

    continuations.withValue { continuations in
      for continuation in continuations {
        continuation.resume()
      }
      continuations.removeAll()
    }

    await store.skipReceivedActions()
  }

  @Test(.dependencies) func taskChecksAllHookSlotsOnStartup() async {
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
      $0[KiroSettingsClient.self].checkInstalled = { progress in
        checkedSlots.withValue { $0.append(progress ? "kiroProgress" : "kiroNotifications") }
        return progress
      }
      $0[PiSettingsClient.self].checkInstalled = {
        checkedSlots.withValue { $0.append("piHooks") }
        return false
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
        "kiroProgress",
        "kiroNotifications",
        "piHooks",
      ])
  }

  @Test(.dependencies) func taskChecksAllSkillsOnStartup() async {
    let checkedSkills = LockIsolated<[String]>([])

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0[CLIInstallerClient.self].checkInstalled = { false }
      $0[ClaudeSettingsClient.self].checkInstalled = { _ in false }
      $0[CodexSettingsClient.self].checkInstalled = { _ in false }
      $0[KiroSettingsClient.self].checkInstalled = { _ in false }
      $0[PiSettingsClient.self].checkInstalled = { false }
      $0[CLISkillClient.self].checkInstalled = { agent in
        let key: String =
          switch agent {
          case .claude: "claude"
          case .codex: "codex"
          case .kiro: "kiro"
          case .pi: "pi"
          }
        checkedSkills.withValue { $0.append(key) }
        return false
      }
    }

    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.task)
    await store.receive(\.settingsLoaded)
    await store.skipReceivedActions()

    #expect(Set(checkedSkills.value) == ["claude", "codex", "kiro", "pi"])
  }

  // MARK: - Kiro hook actions.

  @Test(.dependencies) func agentHookInstallTappedKiroProgressTransitionsToInstalled() async {
    var state = SettingsFeature.State()
    state.kiroProgressState = .notInstalled

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[KiroSettingsClient.self].installProgress = {}
    }

    await store.send(.agentHookInstallTapped(.kiroProgress)) {
      $0.kiroProgressState = .installing
    }
    await store.receive(\.agentHookActionCompleted) {
      $0.kiroProgressState = .installed
    }
  }

  @Test(.dependencies) func agentHookUninstallTappedKiroProgressTransitionsToNotInstalled() async {
    var state = SettingsFeature.State()
    state.kiroProgressState = .installed

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[KiroSettingsClient.self].uninstallProgress = {}
    }

    await store.send(.agentHookUninstallTapped(.kiroProgress)) {
      $0.kiroProgressState = .uninstalling
    }
    await store.receive(\.agentHookActionCompleted) {
      $0.kiroProgressState = .notInstalled
    }
  }

  @Test(.dependencies) func agentHookInstallTappedKiroNotificationsTransitionsToInstalled() async {
    var state = SettingsFeature.State()
    state.kiroNotificationsState = .notInstalled

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[KiroSettingsClient.self].installNotifications = {}
    }

    await store.send(.agentHookInstallTapped(.kiroNotifications)) {
      $0.kiroNotificationsState = .installing
    }
    await store.receive(\.agentHookActionCompleted) {
      $0.kiroNotificationsState = .installed
    }
  }

  @Test(.dependencies) func agentHookUninstallTappedKiroNotificationsTransitionsToNotInstalled() async {
    var state = SettingsFeature.State()
    state.kiroNotificationsState = .installed

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[KiroSettingsClient.self].uninstallNotifications = {}
    }

    await store.send(.agentHookUninstallTapped(.kiroNotifications)) {
      $0.kiroNotificationsState = .uninstalling
    }
    await store.receive(\.agentHookActionCompleted) {
      $0.kiroNotificationsState = .notInstalled
    }
  }

  @Test(.dependencies) func agentHookCheckedKiroProgressSetsInstalled() async {
    var state = SettingsFeature.State()
    state.kiroProgressState = .checking

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.agentHookChecked(.kiroProgress, installed: true)) {
      $0.kiroProgressState = .installed
    }
  }

  @Test(.dependencies) func agentHookCheckedKiroNotificationsSetsNotInstalled() async {
    var state = SettingsFeature.State()
    state.kiroNotificationsState = .checking

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.agentHookChecked(.kiroNotifications, installed: false)) {
      $0.kiroNotificationsState = .notInstalled
    }
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

  // MARK: - Pi hooks.

  @Test(.dependencies) func piHookCheckedSetsInstalled() async {
    var state = SettingsFeature.State()
    state.piHooksState = .checking

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.agentHookChecked(.piHooks, installed: true)) {
      $0.piHooksState = .installed
    }
  }

  @Test(.dependencies) func piHookCheckedSetsNotInstalled() async {
    var state = SettingsFeature.State()
    state.piHooksState = .checking

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.agentHookChecked(.piHooks, installed: false)) {
      $0.piHooksState = .notInstalled
    }
  }

  @Test(.dependencies) func piHookInstallTransitionsToInstalledOnSuccess() async {
    var state = SettingsFeature.State()
    state.piHooksState = .notInstalled

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[PiSettingsClient.self].install = {}
    }

    await store.send(.agentHookInstallTapped(.piHooks)) {
      $0.piHooksState = .installing
    }
    await store.receive(\.agentHookActionCompleted) {
      $0.piHooksState = .installed
    }
  }

  @Test(.dependencies) func piHookInstallTransitionsToFailedOnError() async {
    var state = SettingsFeature.State()
    state.piHooksState = .notInstalled

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[PiSettingsClient.self].install = {
        throw PiSettingsInstallerError.extensionNotManaged
      }
    }

    await store.send(.agentHookInstallTapped(.piHooks)) {
      $0.piHooksState = .installing
    }
    await store.receive(\.agentHookActionCompleted) {
      $0.piHooksState = .failed(PiSettingsInstallerError.extensionNotManaged.localizedDescription)
    }
  }

  @Test(.dependencies) func piHookInstallWhileLoadingIsNoOp() async {
    var state = SettingsFeature.State()
    state.piHooksState = .installing

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.agentHookInstallTapped(.piHooks))
  }

  @Test(.dependencies) func piHookUninstallTransitionsToNotInstalledOnSuccess() async {
    var state = SettingsFeature.State()
    state.piHooksState = .installed

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[PiSettingsClient.self].uninstall = {}
    }

    await store.send(.agentHookUninstallTapped(.piHooks)) {
      $0.piHooksState = .uninstalling
    }
    await store.receive(\.agentHookActionCompleted) {
      $0.piHooksState = .notInstalled
    }
  }

  @Test(.dependencies) func piHookUninstallTransitionsToFailedOnError() async {
    var state = SettingsFeature.State()
    state.piHooksState = .installed

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[PiSettingsClient.self].uninstall = {
        throw PiSettingsInstallerError.extensionNotManaged
      }
    }

    await store.send(.agentHookUninstallTapped(.piHooks)) {
      $0.piHooksState = .uninstalling
    }
    await store.receive(\.agentHookActionCompleted) {
      $0.piHooksState = .failed(PiSettingsInstallerError.extensionNotManaged.localizedDescription)
    }
  }

  @Test(.dependencies) func piHookUninstallWhileLoadingIsNoOp() async {
    var state = SettingsFeature.State()
    state.piHooksState = .uninstalling

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.agentHookUninstallTapped(.piHooks))
  }

  @Test(.dependencies) func piSkillCheckedSetsInstalled() async {
    var state = SettingsFeature.State()
    state.piSkillState = .checking

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.cliSkillChecked(agent: .pi, installed: true)) {
      $0.piSkillState = .installed
    }
  }

  @Test(.dependencies) func piSkillInstallTransitionsToInstalledOnSuccess() async {
    var state = SettingsFeature.State()
    state.piSkillState = .notInstalled

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[CLISkillClient.self].install = { _ in }
    }

    await store.send(.cliSkillInstallTapped(.pi)) {
      $0.piSkillState = .installing
    }
    await store.receive(\.cliSkillCompleted) {
      $0.piSkillState = .installed
    }
  }

  @Test(.dependencies) func piSkillInstallTransitionsToFailedOnError() async {
    var state = SettingsFeature.State()
    state.piSkillState = .notInstalled

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[CLISkillClient.self].install = { _ in
        throw PiSettingsInstallerError.extensionNotManaged
      }
    }

    await store.send(.cliSkillInstallTapped(.pi)) {
      $0.piSkillState = .installing
    }
    await store.receive(\.cliSkillCompleted) {
      $0.piSkillState = .failed(PiSettingsInstallerError.extensionNotManaged.localizedDescription)
    }
  }

  @Test(.dependencies) func piSkillUninstallTransitionsToNotInstalledOnSuccess() async {
    var state = SettingsFeature.State()
    state.piSkillState = .installed

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[CLISkillClient.self].uninstall = { _ in }
    }

    await store.send(.cliSkillUninstallTapped(.pi)) {
      $0.piSkillState = .uninstalling
    }
    await store.receive(\.cliSkillCompleted) {
      $0.piSkillState = .notInstalled
    }
  }

  @Test(.dependencies) func piSkillInstallWhileLoadingIsNoOp() async {
    var state = SettingsFeature.State()
    state.piSkillState = .installing

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.cliSkillInstallTapped(.pi))
  }

  @Test(.dependencies) func piSkillUninstallWhileLoadingIsNoOp() async {
    var state = SettingsFeature.State()
    state.piSkillState = .uninstalling

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.cliSkillUninstallTapped(.pi))
  }
}
