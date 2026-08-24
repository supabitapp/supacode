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

    await store.send(.agentIntegrationInstallTapped(.standard(.claude))) {
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

    await store.send(.agentIntegrationInstallTapped(.standard(.codex))) {
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

    await store.send(.agentIntegrationInstallTapped(.standard(.claude))) {
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

    let completion = SettingsFeature.Action.agentIntegrationCompleted(
      .standard(.grok), .failure(IntegrationTestError.boom), failureIsTransient: true, expected: .installed)
    await store.send(completion) {
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
      .standard(.grok), .failure(IntegrationTestError.boom), failureIsTransient: false, expected: .installed)
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

    await store.send(.agentIntegrationInstallTapped(.standard(.claude))) {
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

    await store.send(.agentIntegrationUninstallTapped(.standard(.kiro))) {
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

    await store.send(.agentIntegrationUninstallTapped(.standard(.pi))) {
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
      $0[AgentIntegrationClient.self].state = { target in
        checked.withValue { $0.insert(target.agent) }
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

    await store.send(.agentIntegrationChecked(.standard(.claude), .success(.outdated))) {
      $0.agentIntegrationStates[.claude] = .ready(.outdated)
      $0.autoInstalledTargets.insert(.standard(.claude))
    }
    await store.receive(\.agentIntegrationInstallTapped) {
      $0.agentIntegrationStates[.claude] = .installing
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.claude] = .ready(.installed)
    }
  }

  @Test(.dependencies) func installingTwoFoldersOfOneAgentDoesNotCancelAcrossTargets() async {
    // The default and a custom folder are distinct targets, so installing one
    // must never cancel an in-flight install of the other. A per-agent
    // `AgentIntegrationCancelID` would corrupt the first write the moment the
    // second target starts; the id is per-target for exactly this reason.
    let customTarget = AgentInstallTarget(
      agent: .claude, location: .custom(configDirectoryPath: "/tmp/supacode-claude-gn"))
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.standard(.claude)] = .ready(.notInstalled)
    state.agentIntegrationStates[customTarget] = .ready(.notInstalled)

    let standardCancelled = LockIsolated(false)
    let standardStored = LockIsolated<CheckedContinuation<Void, Error>?>(nil)
    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { target in
        // Only the default target blocks; the custom one returns immediately.
        guard target.location == .standard else { return }
        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            standardStored.withValue { slot in
              if Task.isCancelled { cont.resume(throwing: CancellationError()) } else { slot = cont }
            }
          }
        } onCancel: {
          standardCancelled.setValue(true)
          standardStored.withValue { slot in
            slot?.resume(throwing: CancellationError())
            slot = nil
          }
        }
      }
      $0[AgentIntegrationClient.self].state = { _ in .installed }
    }

    // Start the default install; it suspends.
    await store.send(.agentIntegrationInstallTapped(.standard(.claude))) {
      $0.agentIntegrationStates[.standard(.claude)] = .installing
    }
    // Install the custom folder; it completes without disturbing the default.
    await store.send(.agentIntegrationInstallTapped(customTarget)) {
      $0.agentIntegrationStates[customTarget] = .installing
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[customTarget] = .ready(.installed)
    }
    #expect(!standardCancelled.value)

    // Let the default finish; it completes normally, never cancelled.
    standardStored.withValue { $0?.resume(returning: ()) }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.standard(.claude)] = .ready(.installed)
    }
    #expect(!standardCancelled.value)
  }

  @Test(.dependencies) func outdatedHealsEachTargetIndependently() async {
    // The once-per-session auto-heal guard is per target: healing a custom
    // folder must not consume the default's heal. A per-agent guard would leave
    // the default's drift unrepaired (or vice versa).
    let customTarget = AgentInstallTarget(
      agent: .claude, location: .custom(configDirectoryPath: "/tmp/supacode-claude-gn"))
    @Shared(.agentsFile) var agentsFile
    $agentsFile.withLock { $0.agents = [customTarget.installRecord] }
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.standard(.claude)] = .ready(.installed)
    state.agentIntegrationStates[customTarget] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in }
      $0[AgentIntegrationClient.self].state = { _ in .installed }
    }

    // The custom folder drifts and heals once.
    await store.send(.agentIntegrationChecked(customTarget, .success(.outdated))) {
      $0.agentIntegrationStates[customTarget] = .ready(.outdated)
      $0.autoInstalledTargets.insert(customTarget)
    }
    await store.receive(\.agentIntegrationInstallTapped) {
      $0.agentIntegrationStates[customTarget] = .installing
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[customTarget] = .ready(.installed)
    }

    // The default drifts and heals independently, though the custom already
    // consumed its own guard.
    await store.send(.agentIntegrationChecked(.standard(.claude), .success(.outdated))) {
      $0.agentIntegrationStates[.standard(.claude)] = .ready(.outdated)
      $0.autoInstalledTargets.insert(.standard(.claude))
    }
    await store.receive(\.agentIntegrationInstallTapped) {
      $0.agentIntegrationStates[.standard(.claude)] = .installing
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.standard(.claude)] = .ready(.installed)
    }
    #expect(store.state.autoInstalledTargets == [.standard(.claude), customTarget])

    // A second drift of the default does not re-heal: its guard is already set.
    await store.send(.agentIntegrationChecked(.standard(.claude), .success(.outdated))) {
      $0.agentIntegrationStates[.standard(.claude)] = .ready(.outdated)
    }
  }

  @Test(.dependencies) func installingAnAgentRecordsItInAgentsFile() async {
    @Shared(.agentsFile) var agentsFile
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.standard(.claude)] = .ready(.notInstalled)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in }
      $0[AgentIntegrationClient.self].state = { _ in .installed }
    }

    await store.send(.agentIntegrationInstallTapped(.standard(.claude))) {
      $0.agentIntegrationStates[.standard(.claude)] = .installing
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.standard(.claude)] = .ready(.installed)
    }
    #expect(agentsFile.agents == [AgentInstallRecord(agent: .claude, path: nil)])
  }

  @Test(.dependencies) func uninstallingAnAgentRemovesItsRecord() async {
    @Shared(.agentsFile) var agentsFile
    $agentsFile.withLock { $0.agents = [AgentInstallRecord(agent: .claude, path: nil)] }
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.standard(.claude)] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].uninstall = { _ in }
      $0[AgentIntegrationClient.self].state = { _ in .notInstalled }
    }

    await store.send(.agentIntegrationUninstallTapped(.standard(.claude))) {
      $0.agentIntegrationStates[.standard(.claude)] = .uninstalling
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.standard(.claude)] = .ready(.notInstalled)
    }
    #expect(agentsFile.agents.isEmpty)
  }

  @Test(.dependencies) func probingAnInstalledDefaultReconcilesItIntoAgentsFile() async {
    // A default install found on disk with no record earns one, so `agents.json`
    // reconciles to what's actually installed.
    @Shared(.agentsFile) var agentsFile
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in }
      $0[AgentIntegrationClient.self].state = { _ in .installed }
    }

    await store.send(.agentIntegrationChecked(.standard(.claude), .success(.installed))) {
      $0.agentIntegrationStates[.standard(.claude)] = .ready(.installed)
    }
    #expect(agentsFile.agents == [AgentInstallRecord(agent: .claude, path: nil)])
  }

  @Test(.dependencies) func refreshProbesRecordedCustomFolders() async {
    let customTarget = AgentInstallTarget(
      agent: .claude, location: .custom(configDirectoryPath: "/tmp/supacode-claude-gn"))
    @Shared(.agentsFile) var agentsFile
    $agentsFile.withLock {
      $0.agents = [AgentInstallRecord(agent: .claude, path: "/tmp/supacode-claude-gn")]
    }
    let probed = LockIsolated<Set<AgentInstallTarget>>([])
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].state = { target in
        probed.withValue { $0.insert(target) }
        return .installed
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.refreshAgentIntegrationStates)
    await store.skipReceivedActions()

    #expect(probed.value.contains(customTarget))
    #expect(store.state.agentIntegrationStates[customTarget] == .ready(.installed))
  }

  @Test(.dependencies) func refreshIgnoresCustomFolderForNonRelocatableAgent() async {
    // Kiro can't be relocated, so a hand-edited/version-flipped custom record
    // must never surface a row that would silently write to the default dir.
    let customTarget = AgentInstallTarget(
      agent: .kiro, location: .custom(configDirectoryPath: "/tmp/supacode-kiro-gn"))
    @Shared(.agentsFile) var agentsFile
    $agentsFile.withLock {
      $0.agents = [AgentInstallRecord(agent: .kiro, path: "/tmp/supacode-kiro-gn")]
    }
    let probed = LockIsolated<Set<AgentInstallTarget>>([])
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].state = { target in
        probed.withValue { $0.insert(target) }
        return .notInstalled
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.refreshAgentIntegrationStates)
    await store.skipReceivedActions()

    #expect(!probed.value.contains(customTarget))
    #expect(store.state.agentIntegrationStates[customTarget] == nil)
  }

  @Test(.dependencies) func pickingACustomFolderInstallsAndRecordsIt() async {
    @Shared(.agentsFile) var agentsFile
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-claude-gn-\(UUID().uuidString)", directoryHint: .isDirectory)
    let path = folder.standardizedFileURL.path(percentEncoded: false)
    let target = AgentInstallTarget(agent: .claude, location: .custom(configDirectoryPath: path))
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.standard(.claude)] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0.directoryPicker.pickDirectory = { _ in folder }
      $0[AgentIntegrationClient.self].install = { _ in }
      $0[AgentIntegrationClient.self].state = { _ in .installed }
    }

    await store.send(.agentAddCustomFolderTapped(.claude))
    await store.receive(\.agentCustomFolderPicked) {
      $0.configDirectoriesOnDisk.insert(target)
    }
    await store.receive(\.agentIntegrationInstallTapped) {
      $0.agentIntegrationStates[target] = .installing
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[target] = .ready(.installed)
    }
    #expect(agentsFile.agents.contains(AgentInstallRecord(agent: .claude, path: path)))
  }

  @Test(.dependencies) func pickingAFolderAlreadyInUseIsRejectedWithAnAlert() async {
    let claudeDefault = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".claude", directoryHint: .isDirectory)
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.standard(.claude)] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0.directoryPicker.pickDirectory = { _ in claudeDefault }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Grok tries to claim Claude's default directory: refused, nothing installed.
    await store.send(.agentAddCustomFolderTapped(.grok))
    await store.skipReceivedActions()
    #expect(store.state.alert != nil)
    #expect(!store.state.agentIntegrationStates.keys.contains { $0.location != .standard })
  }

  @Test(.dependencies) func cancellingTheFolderPickerDoesNothing() async {
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.standard(.claude)] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0.directoryPicker.pickDirectory = { _ in nil }
    }

    await store.send(.agentAddCustomFolderTapped(.claude))
    await store.finish()
  }

  @Test(.dependencies) func uninstallingACustomFolderDropsBothTheRowAndItsRecord() async {
    let customTarget = AgentInstallTarget(
      agent: .claude, location: .custom(configDirectoryPath: "/tmp/supacode-claude-gn"))
    @Shared(.agentsFile) var agentsFile
    $agentsFile.withLock {
      $0.agents = [
        AgentInstallRecord(agent: .claude, path: nil),
        AgentInstallRecord(agent: .claude, path: "/tmp/supacode-claude-gn"),
      ]
    }
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.standard(.claude)] = .ready(.installed)
    state.agentIntegrationStates[customTarget] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].uninstall = { _ in }
      $0[AgentIntegrationClient.self].state = { _ in .notInstalled }
    }

    await store.send(.agentIntegrationUninstallTapped(customTarget)) {
      $0.agentIntegrationStates[customTarget] = .uninstalling
    }
    await store.receive(\.agentIntegrationCompleted) {
      // The custom row disappears entirely; the default row is untouched.
      $0.agentIntegrationStates[customTarget] = nil
    }
    #expect(store.state.agentIntegrationStates[.standard(.claude)] == .ready(.installed))
    #expect(agentsFile.agents == [AgentInstallRecord(agent: .claude, path: nil)])
  }

  @Test(.dependencies) func aRecordedCustomFolderMissingOnDiskStaysVisibleAndKeepsItsRecord() async {
    let customTarget = AgentInstallTarget(
      agent: .claude, location: .custom(configDirectoryPath: "/tmp/supacode-claude-gn"))
    @Shared(.agentsFile) var agentsFile
    $agentsFile.withLock { $0.agents = [AgentInstallRecord(agent: .claude, path: "/tmp/supacode-claude-gn")] }
    var state = SettingsFeature.State()
    state.agentIntegrationStates[customTarget] = .ready(.installed)

    let store = TestStore(initialState: state) { SettingsFeature() }

    // Its files vanished externally: the probe now reads notInstalled.
    await store.send(.agentIntegrationChecked(customTarget, .success(.notInstalled))) {
      $0.agentIntegrationStates[customTarget] = .ready(.notInstalled)
    }
    // The row stays as a recoverable wrong install, and the record is not dropped.
    #expect(store.state.mainListAgentRows.contains(.claude))
    #expect(agentsFile.agents == [AgentInstallRecord(agent: .claude, path: "/tmp/supacode-claude-gn")])
  }

  @Test(.dependencies) func aFailedCustomInstallKeepsItsRecordForRetry() async {
    @Shared(.agentsFile) var agentsFile
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-gn-\(UUID().uuidString)", directoryHint: .isDirectory)
    let path = folder.standardizedFileURL.path(percentEncoded: false)
    let target = AgentInstallTarget(agent: .claude, location: .custom(configDirectoryPath: path))
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.standard(.claude)] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0.directoryPicker.pickDirectory = { _ in folder }
      $0[AgentIntegrationClient.self].install = { _ in throw IntegrationTestError.boom }
    }

    await store.send(.agentAddCustomFolderTapped(.claude))
    await store.receive(\.agentCustomFolderPicked) {
      $0.configDirectoriesOnDisk.insert(target)
    }
    await store.receive(\.agentIntegrationInstallTapped) {
      $0.agentIntegrationStates[target] = .installing
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[target] = .failed("boom")
    }
    // Recorded at pick time and kept through the failure, so the row is recoverable.
    #expect(agentsFile.agents.contains(AgentInstallRecord(agent: .claude, path: path)))
  }

  @Test(.dependencies) func pickingAFolderAlreadyUsedByACustomTargetIsRejected() async {
    // A folder that does NOT exist on disk: its canonical path must still match the
    // recorded custom target, or the duplicate-folder guard silently passes.
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-dup-\(UUID().uuidString)", directoryHint: .isDirectory)
    let existing = AgentInstallTarget(
      agent: .claude, location: .custom(configDirectoryPath: folder.standardizedFileURL.path(percentEncoded: false)))
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.standard(.claude)] = .ready(.installed)
    state.agentIntegrationStates[existing] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0.directoryPicker.pickDirectory = { _ in folder }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Codex tries to claim the folder already backing Claude's custom install.
    await store.send(.agentAddCustomFolderTapped(.codex))
    await store.skipReceivedActions()
    #expect(store.state.alert != nil)
    #expect(!store.state.agentIntegrationStates.keys.contains { $0.agent == .codex && $0.location != .standard })
  }

  @Test(.dependencies) func refreshResolvesWhichConfigDirectoriesExistOnDisk() async {
    let existingDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-exists-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: existingDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: existingDir) }
    let existingPath = existingDir.standardizedFileURL.path(percentEncoded: false)
    let missingPath = "/tmp/supacode-nope-\(UUID().uuidString)"
    let present = AgentInstallTarget(agent: .claude, location: .custom(configDirectoryPath: existingPath))
    let missing = AgentInstallTarget(agent: .claude, location: .custom(configDirectoryPath: missingPath))

    @Shared(.agentsFile) var agentsFile
    $agentsFile.withLock {
      $0.agents = [
        AgentInstallRecord(agent: .claude, path: existingPath),
        AgentInstallRecord(agent: .claude, path: missingPath),
      ]
    }
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].state = { _ in .notInstalled }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.refreshAgentIntegrationStates)
    await store.skipReceivedActions()

    #expect(store.state.configDirectoriesOnDisk.contains(present))
    #expect(!store.state.configDirectoriesOnDisk.contains(missing))
  }

  @Test(.dependencies) func aFailedAgentsFileSaveOnPickAbortsWithAnAlert() async {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-gn-\(UUID().uuidString)", directoryHint: .isDirectory)
    let target = AgentInstallTarget(
      agent: .claude, location: .custom(configDirectoryPath: folder.standardizedFileURL.path(percentEncoded: false)))
    let installRan = LockIsolated(false)
    @Shared(.agentsFile) var agentsFile
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.standard(.claude)] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0.directoryPicker.pickDirectory = { _ in folder }
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try Data(contentsOf: $0) }, save: { _, _ in throw IntegrationTestError.boom })
      $0[AgentIntegrationClient.self].install = { _ in installRan.setValue(true) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.agentAddCustomFolderTapped(.claude))
    await store.skipReceivedActions()

    // The record couldn't persist, so the install is aborted, the row never
    // appears, and the in-memory record is rolled back.
    #expect(store.state.alert != nil)
    #expect(!installRan.value)
    #expect(store.state.agentIntegrationStates[target] == nil)
    #expect(agentsFile.agents.isEmpty)
  }

  @Test(.dependencies) func aFailedSaveOnPickKeepsAPreExistingRecordForThatFolder() async {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-gn-\(UUID().uuidString)", directoryHint: .isDirectory)
    let record = AgentInstallRecord(agent: .claude, path: folder.standardizedFileURL.path(percentEncoded: false))
    @Shared(.agentsFile) var agentsFile
    $agentsFile.withLock { $0.agents = [record] }
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.standard(.claude)] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0.directoryPicker.pickDirectory = { _ in folder }
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try Data(contentsOf: $0) }, save: { _, _ in throw IntegrationTestError.boom })
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.agentAddCustomFolderTapped(.claude))
    await store.skipReceivedActions()

    // The append was skipped (the record already existed), so the failed save's
    // rollback must not delete it.
    #expect(agentsFile.agents == [record])
    #expect(store.state.alert != nil)
  }

  @Test func aCustomOnlyInstallReadsAsInstalledForTheSidebarUpsell() {
    let customTarget = AgentInstallTarget(
      agent: .claude, location: .custom(configDirectoryPath: "/tmp/supacode-claude-gn"))
    var state = SettingsFeature.State()
    // Default not installed, only a custom folder is.
    state.agentIntegrationStates[.standard(.claude)] = .ready(.notInstalled)
    state.agentIntegrationStates[customTarget] = .ready(.installed)
    // The per-agent projection the sidebar reads must report Claude installed,
    // so the "Advanced agent integration" prompt stays hidden.
    #expect(state.standardAgentIntegrationStates[.claude] == .ready(.installed))

    // A custom probe still in flight keeps the agent unresolved, so a slow custom
    // install never flashes a false upsell.
    let pendingCustom = AgentInstallTarget(agent: .codex, location: .custom(configDirectoryPath: "/tmp/y"))
    var pending = SettingsFeature.State()
    pending.agentIntegrationStates[.standard(.codex)] = .ready(.notInstalled)
    pending.agentIntegrationStates[pendingCustom] = .checking
    #expect(pending.standardAgentIntegrationStates[.codex]?.isInFlight == true)
  }

  @Test(.dependencies) func aStaleProbeForARemovedCustomFolderIsDiscarded() async {
    let customTarget = AgentInstallTarget(
      agent: .claude, location: .custom(configDirectoryPath: "/tmp/supacode-removed-gn"))
    @Shared(.agentsFile) var agentsFile
    // agents.json holds no record: the folder was uninstalled while a probe was in flight.
    let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }

    await store.send(.agentIntegrationChecked(customTarget, .success(.installed)))

    // The row is not recreated and the deleted record is not resurrected.
    #expect(store.state.agentIntegrationStates[customTarget] == nil)
    #expect(agentsFile.agents.isEmpty)
  }

  @Test func agentWithACustomFolderStaysInTheMainListNotTheSheet() {
    let customTarget = AgentInstallTarget(
      agent: .claude, location: .custom(configDirectoryPath: "/tmp/supacode-claude-gn"))
    var state = SettingsFeature.State()
    // Default not installed, but a custom folder is: the agent still belongs in
    // the main list, and its rows are the default plus the custom folder.
    state.agentIntegrationStates[.standard(.claude)] = .ready(.notInstalled)
    state.agentIntegrationStates[customTarget] = .ready(.installed)

    #expect(state.mainListAgentRows.contains(.claude))
    #expect(!state.uninstalledAgents.contains(.claude))
    #expect(!state.agentInstallSheetAgents.contains(.claude))
    #expect(state.installTargets(for: .claude) == [.standard(.claude), customTarget])
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

    await store.send(.agentIntegrationChecked(.standard(.claude), .success(.outdated)))
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

    await store.send(.agentIntegrationChecked(.standard(.claude), .success(.outdated)))
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

    await store.send(.agentIntegrationInstallTapped(.standard(.claude))) {
      $0.agentIntegrationStates[.claude] = .installing
    }
    secondInstallStarted.setValue(true)
    await store.send(.agentIntegrationInstallTapped(.standard(.claude)))
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

    await store.send(.agentIntegrationInstallTapped(.standard(.grok))) {
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

    await store.send(.agentIntegrationInstallTapped(.standard(.grok))) {
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

    await store.send(.agentIntegrationInstallTapped(.standard(.grok))) {
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
    await store.send(
      .agentIntegrationCompleted(
        .standard(.grok), .success(.installed), failureIsTransient: false, expected: .installed)
    ) {
      $0.agentIntegrationStates[.grok] = .ready(.installed)
    }
  }

  @Test(.dependencies) func installThatDoesNotLandSurfacesAFailure() async {
    // The install reported success but the follow-up read still says outdated,
    // so the write did not land. Rendering that as a normal row would make a
    // silently failed install invisible.
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

    await store.send(.agentIntegrationInstallTapped(.standard(.grok))) {
      $0.agentIntegrationStates[.grok] = .installing
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.grok] = .failed(
        "Installed the Grok Code integration, but it still reads as out of date on disk.")
      $0.agentInstallSheetPresented = false
    }
  }

  @Test(.dependencies) func uninstallThatDoesNotLandSurfacesAFailure() async {
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.kiro] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].uninstall = { _ in }
      $0[AgentIntegrationClient.self].state = { _ in .installed }
    }

    await store.send(.agentIntegrationUninstallTapped(.standard(.kiro))) {
      $0.agentIntegrationStates[.kiro] = .uninstalling
    }
    await store.receive(\.agentIntegrationCompleted) {
      $0.agentIntegrationStates[.kiro] = .failed(
        "Removed the Kiro CLI integration, but it still reads as installed on disk.")
    }
  }

  @Test(.dependencies) func installSucceedsButUnreadableProbeIsUnverifiedNotFailed() async {
    // The write itself succeeded; only the confirming read failed. Calling that
    // a failure would invent an outcome we never observed.
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.claude] = .ready(.notInstalled)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in }
      $0[AgentIntegrationClient.self].state = { _ in throw unreadableProbeError }
    }

    await store.send(.agentIntegrationInstallTapped(.standard(.claude))) {
      $0.agentIntegrationStates[.claude] = .installing
    }
    await store.receive(\.agentIntegrationUnverified) {
      $0.agentIntegrationStates[.claude] = .undetermined(
        lastKnown: .notInstalled,
        reason: "Installed the Claude Code integration, but couldn't read it back to confirm. "
          + "Couldn't read ~/.claude/settings.json: Operation not permitted. "
          + "Supacode retries when you switch back to it."
      )
    }
  }

  @Test(.dependencies) func uninstallSucceedsButUnreadableProbeIsUnverifiedNotRemoved() async {
    // The removal may well have landed, so the row must not claim it did and
    // must not claim it failed either.
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.kiro] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].uninstall = { _ in }
      $0[AgentIntegrationClient.self].state = { _ in throw unreadableProbeError }
    }

    await store.send(.agentIntegrationUninstallTapped(.standard(.kiro))) {
      $0.agentIntegrationStates[.kiro] = .uninstalling
    }
    await store.receive(\.agentIntegrationUnverified) {
      $0.agentIntegrationStates[.kiro] = .undetermined(
        lastKnown: .installed,
        reason: "Removed the Kiro CLI integration, but couldn't read it back to confirm. "
          + "Couldn't read ~/.claude/settings.json: Operation not permitted. "
          + "Supacode retries when you switch back to it."
      )
    }
  }

  @Test(.dependencies) func unverifiedInstallKeepsTheAutoInstallMemory() async {
    // An install that could not be read back must not erase the guard's memory,
    // or every activation re-arms another unattended rewrite.
    let installCount = LockIsolated(0)
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in installCount.withValue { $0 += 1 } }
      $0[AgentIntegrationClient.self].state = { _ in throw unreadableProbeError }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Auto-arms, installs, then fails to read the result back.
    await store.send(.agentIntegrationChecked(.standard(.claude), .success(.outdated)))
    await store.skipReceivedActions()
    #expect(installCount.value == 1)

    // A later activation reads `.outdated` again; the install must not re-fire.
    await store.send(.agentIntegrationChecked(.standard(.claude), .success(.outdated)))
    #expect(installCount.value == 1)
  }

  @Test(.dependencies) func installSheetDismissesWhenRefreshResolvesLastAgentInstalled() async {
    var state = SettingsFeature.State()
    for agent in SkillAgent.allCases { state.agentIntegrationStates[agent] = .ready(.installed) }
    state.agentIntegrationStates[.grok] = .ready(.notInstalled)
    state.agentInstallSheetPresented = true

    let store = TestStore(initialState: state) { SettingsFeature() }

    // Grok is installed externally; a scene-activation refresh observes it and
    // must empty-and-dismiss the sheet, not only the completed-install path.
    await store.send(.agentIntegrationChecked(.standard(.grok), .success(.installed))) {
      $0.agentIntegrationStates[.grok] = .ready(.installed)
      $0.agentInstallSheetPresented = false
    }
  }

  @Test(.dependencies) func outdatedRecheckDoesNotReArmInstallWhenAlreadyOutdated() async {
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.claude] = .ready(.outdated)
    state.autoInstalledTargets = [.standard(.claude)]

    let store = TestStore(initialState: state) { SettingsFeature() }

    // A prior re-install already left it outdated, so a re-check must not
    // re-fire the install (no `.agentIntegrationInstallTapped` is received).
    await store.send(.agentIntegrationChecked(.standard(.claude), .success(.outdated)))
  }

  @Test(.dependencies) func autoInstallArmsAtMostOncePerSessionAcrossEveryIntermediateState() async {
    // The anti-loop invariant, driven through the states that used to erase it:
    // an in-flight second tap, an unreadable probe, and the `.checking` reset a
    // sheet dismissal performs. None of them may buy a second unattended write.
    let installCount = LockIsolated(0)
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in installCount.withValue { $0 += 1 } }
      $0[AgentIntegrationClient.self].state = { _ in .outdated }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.agentIntegrationChecked(.standard(.claude), .success(.outdated)))
    await store.skipReceivedActions()
    #expect(store.state.autoInstalledTargets.contains(.standard(.claude)))

    // A user tap on top of the in-flight install, then a fault, then recovery.
    await store.send(.agentIntegrationInstallTapped(.standard(.claude)))
    await store.skipReceivedActions()
    await store.send(.agentIntegrationChecked(.standard(.claude), .failure(unreadableProbeError)))
    await store.send(.agentIntegrationChecked(.standard(.claude), .success(.outdated)))

    // The manual tap ran; the auto-update never armed a second time.
    #expect(installCount.value == 2)
  }

  @Test(.dependencies) func dismissingTheSheetDoesNotBuyASecondAutoInstall() async {
    // Dismissing the sheet resets transiently-failed rows to `.checking` and
    // re-probes. That reset must not read as "never auto-installed".
    let installCount = LockIsolated(0)
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.claude] = .failedTransient("earlier")
    state.autoInstalledTargets = [.standard(.claude)]
    state.agentInstallSheetPresented = true

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in installCount.withValue { $0 += 1 } }
      $0[AgentIntegrationClient.self].state = { $0.agent == .claude ? .outdated : .installed }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.setAgentInstallSheetPresented(false))
    await store.skipReceivedActions()

    #expect(installCount.value == 0)
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
      .standard(.claude): .ready(.installed),
      .standard(.codex): .ready(.outdated),
      .standard(.grok): .ready(.notInstalled),
      .standard(.kiro): .installing,
      .standard(.omp): .failedTransient("boom"),  // install error: modal-only.
      .standard(.pi): .failed("nope"),  // uninstall / update error: main list.
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

  // MARK: - Undeterminable probes.

  @Test(.dependencies) func unreadableProbeKeepsLastKnownStateAndDoesNotAutoInstall() async {
    // The whole point of the fix: an unreadable file must not read as "not
    // installed", must not clobber what we already knew, and must not arm an
    // unattended rewrite of a file we just failed to read.
    let installRan = LockIsolated(false)
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.claude] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in installRan.setValue(true) }
    }

    await store.send(.agentIntegrationChecked(.standard(.claude), .failure(unreadableProbeError))) {
      $0.agentIntegrationStates[.claude] = .undetermined(
        lastKnown: .installed,
        reason: "Couldn't read ~/.claude/settings.json: Operation not permitted. "
          + "Supacode retries when you switch back to it."
      )
    }
    #expect(!installRan.value)
    // The row stays in the main list rather than collapsing into the
    // "N available" install prompt.
    #expect(store.state.mainListAgentRows.contains(.claude))
    #expect(!store.state.uninstalledAgents.contains(.claude))
  }

  @Test(.dependencies) func unreadableProbeOnColdLaunchWarnsInsteadOfSpinning() async {
    // No previous verdict exists, so keeping the previous state would leave the
    // row on a `ProgressView` forever. It must carry the warning instead.
    let installRan = LockIsolated(false)
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in installRan.setValue(true) }
    }

    await store.send(.agentIntegrationChecked(.standard(.claude), .failure(unreadableProbeError))) {
      $0.agentIntegrationStates[.claude] = .undetermined(
        lastKnown: nil,
        reason: "Couldn't read ~/.claude/settings.json: Operation not permitted. "
          + "Supacode retries when you switch back to it."
      )
    }
    #expect(!installRan.value)
  }

  @Test(.dependencies) func unreadableProbeSelfHealsOnTheNextRefresh() async {
    // `.undetermined` is never sticky: unlike `.failed` it re-probes, so the
    // row recovers as soon as reads work again.
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.claude] = .undetermined(lastKnown: .installed, reason: "nope")

    let store = TestStore(initialState: state) { SettingsFeature() }

    await store.send(.agentIntegrationChecked(.standard(.claude), .success(.installed))) {
      $0.agentIntegrationStates[.claude] = .ready(.installed)
    }
  }

  @Test(.dependencies) func unreadableProbeDoesNotEraseTheAutoInstallMemory() async {
    // A prior re-install already left the integration outdated. An unreadable
    // probe in between must not make the guard forget that, or every activation
    // re-arms an unattended hook rewrite.
    let installRan = LockIsolated(false)
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.claude] = .ready(.outdated)
    state.autoInstalledTargets = [.standard(.claude)]

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in installRan.setValue(true) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.agentIntegrationChecked(.standard(.claude), .failure(unreadableProbeError)))
    await store.send(.agentIntegrationChecked(.standard(.claude), .success(.outdated)))
    #expect(!installRan.value)
  }

  @Test(.dependencies) func malformedProbeIsVisibleAndNotSticky() async {
    // A malformed settings file is a fault the user must see, but it is not
    // sticky: `unreadableProbeSelfHealsOnTheNextRefresh` covers the recovery.
    let installRan = LockIsolated(false)
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.claude] = .ready(.installed)

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentIntegrationClient.self].install = { _ in installRan.setValue(true) }
    }

    await store.send(.agentIntegrationChecked(.standard(.claude), .failure(IntegrationTestError.boom))) {
      $0.agentIntegrationStates[.claude] = .undetermined(
        lastKnown: .installed,
        reason: "Couldn't determine whether the integration is installed. boom. "
          + "Supacode retries when you switch back to it."
      )
    }
    #expect(!installRan.value)
  }

  @Test(.dependencies) func unreadableProbeDoesNotClobberAnInFlightUninstall() async {
    var state = SettingsFeature.State()
    state.agentIntegrationStates[.claude] = .uninstalling

    let store = TestStore(initialState: state) { SettingsFeature() }

    await store.send(.agentIntegrationChecked(.standard(.claude), .failure(unreadableProbeError)))
  }
}

/// Stands in for the reported incident: the settings file exists but the OS
/// refuses the read, so no install state can be derived from it.
private nonisolated let unreadableProbeError = AgentFileUnreadableError(
  displayPath: "~/.claude/settings.json", reason: "Operation not permitted")

private enum IntegrationTestError: LocalizedError {
  case boom
  var errorDescription: String? { "boom" }
}
