import ComposableArchitecture
import CryptoKit
import DependenciesTestSupport
import Foundation
import SupacodeSettingsFeature
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct LicenseTests {
  nonisolated static let key = "SUPACODE-AAAAAAAAAAAAAAAAAAAAAAAAAA-AAAAAAAAAAAAAAAAAAAAAAAAAA"
  nonisolated static let device = LicenseDevice(
    id: "test-device", name: "Test Mac", appVersion: "1.0")

  @Test func reservesOnlyFiveCreationsAndChargesOnlyCompletedWork() async throws {
    let stored = LockIsolated(LicenseRecord())
    let session = Self.session(stored: stored)
    let permits = try await withThrowingTaskGroup(of: LicenseCreationPermit.self) { group in
      for _ in 0..<5 {
        group.addTask { try await session.authorizeCreation(resource: nil) }
      }
      var permits: [LicenseCreationPermit] = []
      for try await permit in group { permits.append(permit) }
      return permits
    }
    await #expect(throws: LicenseError.trialCreationsPending) {
      try await session.authorizeCreation(resource: nil)
    }
    #expect(stored.value.trialCreations == 0)
    _ = try await session.completeCreation(permits[0])
    _ = try await session.completeCreation(permits[0])
    #expect(stored.value.trialCreations == 1)
    for permit in permits.dropFirst() { await session.cancelCreation(permit) }
    let reloaded = Self.session(stored: stored)
    #expect(try await reloaded.load().remainingCreations == 4)
    let next = try await session.authorizeCreation(resource: nil)
    await session.cancelCreation(next)
    #expect(stored.value.trialCreations == 1)
  }

  @Test func requiresALicenseAfterFiveCompletedCreations() async throws {
    let stored = LockIsolated(LicenseRecord())
    let session = Self.session(stored: stored)
    for _ in 0..<5 {
      let permit = try await session.authorizeCreation(resource: nil)
      _ = try await session.completeCreation(permit)
    }
    #expect(stored.value.trialCreations == 5)
    await #expect(throws: LicenseError.licenseRequired) {
      try await session.authorizeCreation(resource: nil)
    }
  }

  @Test func rejectsConcurrentRequestsForTheSameBranch() async throws {
    let stored = LockIsolated(LicenseRecord())
    let session = Self.session(stored: stored)
    let permit = try await session.authorizeCreation(resource: "repository:feature")
    await #expect(throws: LicenseError.creationInProgress) {
      try await session.authorizeCreation(resource: "repository:feature")
    }
    await session.cancelCreation(permit)
    _ = try await session.authorizeCreation(resource: "repository:feature")
    #expect(stored.value.trialCreations == 0)
  }

  @Test func recoversSuccessfulCreationAfterAnInterruptedCopy() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stored = LockIsolated(LicenseRecord())
    let original = Self.session(stored: stored)
    let permit = try await original.authorizeCreation(resource: nil)
    try await original.claimCreationResource(
      permit, resource: "repository:feature", localDirectory: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("gitdir: /tmp/test".utf8).write(to: directory.appending(path: ".git"))
    let restarted = Self.session(stored: stored)
    #expect(try await restarted.load().trialCreations == 1)
    #expect(stored.value.pendingWorktreePaths == nil)
  }

  @Test func journalsCreationIntoAnExistingEmptyDirectory() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stored = LockIsolated(LicenseRecord())
    let session = Self.session(stored: stored)
    let permit = try await session.authorizeCreation(resource: nil)
    try await session.claimCreationResource(
      permit, resource: "repository:first", localDirectory: directory)
    let other = try await session.authorizeCreation(resource: nil)
    await #expect(throws: LicenseError.creationInProgress) {
      try await session.claimCreationResource(
        other, resource: "repository:second", localDirectory: directory)
    }
    try Data("gitdir: /tmp/test".utf8).write(to: directory.appending(path: ".git"))
    #expect(try await Self.session(stored: stored).load().trialCreations == 1)
  }

  @Test(.dependencies) func cancellationChargesOnlyWhenTheCreatedWorktreeSurvives() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("gitdir: /tmp/test".utf8).write(to: directory.appending(path: ".git"))
    defer { try? FileManager.default.removeItem(at: directory) }
    let worktree = Worktree(
      location: .local(workingDirectory: directory, repositoryRoot: directory), kind: .git,
      name: "feature", detail: "", isAttached: false)
    let pending: Worktree.ID = "pending:license-cleanup"
    let permit = LicenseCreationPermit(id: UUID())
    var state = RepositoriesFeature.State()
    state.cancelRequestedPendingIDs = [pending]
    state.licensePermits[pending] = permit
    let completed = LockIsolated(0)
    let cancelled = LockIsolated(0)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { _, _ in directory }
      $0[LicenseClient.self].completeCreation = { _ in
        completed.withValue { $0 += 1 }
        return LicenseSnapshot()
      }
      $0[LicenseClient.self].cancelCreation = { _ in cancelled.withValue { $0 += 1 } }
    }
    store.exhaustivity = .off
    await store.send(
      .createRandomWorktreeSucceeded(
        worktree, repositoryID: RepositoryID(directory.path), pendingID: pending, ownership: .created(at: worktree)))
    // The permit settles first so a license-save problem can join the same alert.
    await store.receive(\.delegate)
    await store.receive(\.presentAlert)
    await store.finish()
    #expect(completed.value == 1)
    #expect(cancelled.value == 0)
  }

  @Test func recoversUnusedReservationWithoutCharging() async throws {
    let stored = LockIsolated(LicenseRecord())
    let session = Self.session(stored: stored)
    let permit = try await session.authorizeCreation(resource: nil)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try await session.claimCreationResource(
      permit, resource: "repository:feature", localDirectory: directory)
    #expect(try await Self.session(stored: stored).load().trialCreations == 0)
  }

  @Test func rejectsTwoRandomReservationsResolvingToTheSameBranch() async throws {
    let session = Self.session(stored: LockIsolated(LicenseRecord()))
    let first = try await session.authorizeCreation(resource: nil)
    let second = try await session.authorizeCreation(resource: nil)
    try await session.claimCreationResource(first, resource: "repository:feature")
    await #expect(throws: LicenseError.creationInProgress) {
      try await session.claimCreationResource(second, resource: "repository:feature")
    }
  }

  @Test(.dependencies) func ignoresStaleSnapshotResponses() async {
    let store = TestStore(initialState: LicenseFeature.State()) { LicenseFeature() }
    var fresh = LicenseSnapshot()
    fresh.trialCreations = 4
    fresh.updateSequence = 2
    await store.send(.snapshotUpdated(fresh)) { $0.apply(fresh) }
    var stale = LicenseSnapshot()
    stale.trialCreations = 2
    stale.updateSequence = 1
    await store.send(.snapshotUpdated(stale))
    #expect(store.state.snapshot.trialCreations == 4)
  }

  @Test func retriesAStorageFailureBeforeAuthorizingMoreWork() async throws {
    let stored = LockIsolated(LicenseRecord())
    let fails = LockIsolated(true)
    let session = LicenseSession(
      persistence: LicensePersistence(
        load: { stored.value },
        save: { record in
          if fails.value { throw LicenseError.storageUnavailable }
          stored.withValue { $0 = record }
        }
      ),
      device: Self.device, isEnforced: true
    )
    let permit = try await session.authorizeCreation(resource: nil)
    await #expect(throws: LicenseError.storageUnavailable) {
      try await session.completeCreation(permit)
    }
    await #expect(throws: LicenseError.storageUnavailable) {
      try await session.authorizeCreation(resource: nil)
    }
    fails.withValue { $0 = false }
    _ = try await session.authorizeCreation(resource: nil)
    #expect(stored.value.trialCreations == 1)
  }

  @Test func retainsOwnedReleaseAccessIndefinitelyOffline() async throws {
    let signingKey = Curve25519.Signing.PrivateKey()
    let token = try Self.token(signingKey: signingKey, updatesThrough: "2020-01-01")
    let stored = LockIsolated(LicenseRecord(key: Self.key, token: token, trialCreations: 5))
    let session = Self.session(
      stored: stored,
      publicKey: signingKey.publicKey.rawRepresentation,
      releaseDay: LicenseDay("2019-12-31")
    )
    await #expect(throws: LicenseError.service("Offline")) { try await session.refresh() }
    #expect(try await session.load().ownsCurrentRelease)
    let permit = try await session.authorizeCreation(resource: nil)
    _ = try await session.completeCreation(permit)
    #expect(stored.value.trialCreations == 5)
  }

  @Test func aNewerUnownedReleaseRequiresActivationOrRenewal() async throws {
    let signingKey = Curve25519.Signing.PrivateKey()
    let token = try Self.token(signingKey: signingKey, updatesThrough: "2026-08-01")
    let stored = LockIsolated(LicenseRecord(key: Self.key, token: token, trialCreations: 5))
    let session = Self.session(
      stored: stored, publicKey: signingKey.publicKey.rawRepresentation,
      releaseDay: LicenseDay("2026-08-02")
    )
    #expect(try await !session.load().ownsCurrentRelease)
    await #expect(throws: LicenseError.licenseRequired) {
      try await session.authorizeCreation(resource: nil)
    }
  }

  @Test(arguments: [false, true])
  func legacyTeamTokensRetainOwnedReleaseAccessOffline(hasLease: Bool) async throws {
    let signingKey = Curve25519.Signing.PrivateKey()
    let token = try Self.token(
      signingKey: signingKey, updatesThrough: "2020-01-01", team: true,
      lease: hasLease ? 2 : nil
    )
    let stored = LockIsolated(LicenseRecord(key: Self.key, token: token, trialCreations: 5))
    let session = Self.session(
      stored: stored, publicKey: signingKey.publicKey.rawRepresentation,
      releaseDay: LicenseDay("2019-12-31")
    )
    await #expect(throws: LicenseError.service("Offline")) { try await session.refresh() }
    #expect(try await session.load().ownsCurrentRelease)
    let permit = try await session.authorizeCreation(resource: nil)
    _ = try await session.completeCreation(permit)
    #expect(stored.value.trialCreations == 5)
  }

  @Test func legacyTeamTokenDoesNotOwnNewerReleases() async throws {
    let signingKey = Curve25519.Signing.PrivateKey()
    let token = try Self.token(
      signingKey: signingKey, updatesThrough: "2020-01-01", team: true, lease: 2)
    let stored = LockIsolated(LicenseRecord(key: Self.key, token: token, trialCreations: 5))
    let session = Self.session(
      stored: stored, publicKey: signingKey.publicKey.rawRepresentation,
      releaseDay: LicenseDay("2020-01-02")
    )
    #expect(try await !session.load().ownsCurrentRelease)
    await #expect(throws: LicenseError.licenseRequired) {
      try await session.authorizeCreation(resource: nil)
    }
  }

  @Test(arguments: ["revoked", "transferred", "deactivated"])
  func cachedTeamAccessEndsAfterASuccessfulServerRefresh(status: String) async throws {
    let signingKey = Curve25519.Signing.PrivateKey()
    let cached = try Self.token(signingKey: signingKey, team: true, lease: 2)
    let updated = try Self.token(signingKey: signingKey, status: status, revision: 2)
    let stored = LockIsolated(LicenseRecord(key: Self.key, token: cached, trialCreations: 5))
    let session = LicenseSession(
      persistence: LicensePersistence(
        load: { stored.value }, save: { updated in stored.withValue { $0 = updated } }),
      device: Self.device, publicKey: signingKey.publicKey.rawRepresentation,
      releaseDay: LicenseDay("2026-10-10"), isEnforced: true,
      request: { _, _, _ in updated }
    )
    #expect(try await session.load().ownsCurrentRelease)
    let refreshed = try await session.refresh()
    #expect(refreshed.entitlement?.status.rawValue == status)
    #expect(!refreshed.ownsCurrentRelease)
    await #expect(throws: LicenseError.licenseRequired) {
      try await session.authorizeCreation(resource: nil)
    }
  }

  @Test func verifiesTheDeviceAndRejectsAlteredTokens() throws {
    let signingKey = Curve25519.Signing.PrivateKey()
    let token = try Self.token(signingKey: signingKey)
    let codec = try LicenseEntitlementCodec(
      publicKeyRawRepresentation: signingKey.publicKey.rawRepresentation)
    let licenseID = try #require(LicenseCredential(Self.key)?.licenseID)
    #expect(
      codec.decode(token: token, expectedDeviceID: Self.device.id, expectedLicenseID: licenseID)
        != nil)
    #expect(
      codec.decode(token: token, expectedDeviceID: "another-mac", expectedLicenseID: licenseID)
        == nil)
    #expect(
      codec.decode(
        token: "A" + token.dropFirst(), expectedDeviceID: Self.device.id,
        expectedLicenseID: licenseID)
        == nil)
    #expect(LicenseCredential(Self.key.replacing("SUPACODE", with: "SUPATERM")) == nil)
  }

  @Test(.dependencies) func activationFailureClearsTheBusyState() async {
    let store = TestStore(initialState: LicenseFeature.State()) { LicenseFeature() }
    await store.send(.binding(.set(\.keyInput, "invalid"))) { $0.keyInput = "invalid" }
    await store.send(.activate) { $0.isBusy = true }
    await store.receive(\.completed) {
      $0.isBusy = false
      $0.errorMessage = LicenseError.invalidKey.localizedDescription
    }
  }

  @Test(.dependencies, arguments: [false, true])
  func purchasePromptRequiresConfirmation(opensCheckout: Bool) async {
    let openedURLs = LockIsolated<[URL]>([])
    let events = LockIsolated<[String]>([])
    let store = TestStore(initialState: LicenseFeature.State()) {
      LicenseFeature()
    } withDependencies: {
      $0.urlOpener.open = { url in openedURLs.withValue { $0.append(url) } }
      $0.analyticsClient.capture = { event, _ in events.withValue { $0.append(event) } }
    }

    await store.send(.purchaseRequired) {
      $0.alert = Self.purchaseAlert
    }
    #expect(openedURLs.value.isEmpty)
    #expect(events.value.isEmpty)

    if opensCheckout {
      await store.send(.alert(.presented(.buy))) {
        $0.alert = nil
      }
      await store.receive(\.buy)
      #expect(openedURLs.value == [URL(string: "https://license.supacode.sh/buy")!])
      #expect(events.value == ["license_checkout_opened"])
    } else {
      await store.send(.alert(.dismiss)) {
        $0.alert = nil
      }
      #expect(openedURLs.value.isEmpty)
      #expect(events.value.isEmpty)
    }
  }

  @Test(.dependencies) func licenseGatePresentsPurchasePromptInsteadOfActivation() async {
    let storage = SettingsTestStorage()
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      TestStore(initialState: AppFeature.State()) {
        AppFeature()
      }
    }

    await store.send(.repositories(.delegate(.licenseRequired)))
    await store.receive(\.license.purchaseRequired) {
      $0.license.alert = Self.purchaseAlert
    }
  }

  private static var purchaseAlert: AlertState<LicenseFeature.Alert> {
    AlertState {
      TextState("License Required")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
      ButtonState(action: .buy) {
        TextState("Buy Supacode")
      }
    } message: {
      TextState(
        """
        A Supacode license is required to create more local worktrees. \
        Buy a license on the website, or activate an existing license in Settings → License.
        """
      )
    }
  }

  @Test(.dependencies) func exhaustedAllowanceNeverStartsLocalGitCreation() async {
    let repository = Repository(
      location: .local(URL(fileURLWithPath: "/tmp/license-test-repository")), kind: .git,
      name: "Test", worktrees: []
    )
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    let calls = LockIsolated(0)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0[LicenseClient.self].isEnforced = true
      $0[LicenseClient.self].authorizeCreation = { _ in throw LicenseError.licenseRequired }
      $0[GitClientDependency.self].createWorktreeStream = { _, _, _, _, _, _, _ in
        calls.withValue { $0 += 1 }
        return AsyncThrowingStream { $0.finish() }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(
      .createWorktreeInRepository(
        repositoryID: repository.id, nameSource: .explicit("feature"),
        baseRefSource: .repositorySetting, fetchOrigin: false
      ))
    await store.receive(\.worktreeCreationRejected)
    await store.receive(\.delegate)
    #expect(store.state.pendingWorktrees.isEmpty)
    #expect(calls.value == 0)
  }

  @Test(.dependencies, arguments: [0, 5], [false, true])
  func sshCreationDoesNotUseTheLocalAllowance(trialCreations: Int, creationFails: Bool) async {
    let host = RemoteHost(alias: "license-test-host")
    let repository = Repository(
      location: .remote(host, path: "/home/me/repo"), kind: .git,
      name: "Test", worktrees: [])
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    let stored = LockIsolated(LicenseRecord(trialCreations: trialCreations))
    let session = Self.session(stored: stored)
    let licenseCalls = LockIsolated(0)
    let commands = LockIsolated<[String]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature().worktreeCreateInRepoReducer
    } withDependencies: {
      $0[LicenseClient.self].isEnforced = true
      $0[LicenseClient.self].authorizeCreation = { resource in
        licenseCalls.withValue { $0 += 1 }
        return try await session.authorizeCreation(resource: resource)
      }
      $0[LicenseClient.self].claimCreationResource = { permit, resource, directory in
        licenseCalls.withValue { $0 += 1 }
        try await session.claimCreationResource(
          permit, resource: resource, localDirectory: directory)
      }
      $0[LicenseClient.self].completeCreation = { permit in
        licenseCalls.withValue { $0 += 1 }
        return try await session.completeCreation(permit)
      }
      $0[LicenseClient.self].cancelCreation = { permit in
        licenseCalls.withValue { $0 += 1 }
        await session.cancelCreation(permit)
      }
      $0.shellClient.run = { executable, arguments, directory in
        #expect(executable.path == "/usr/bin/ssh")
        #expect(directory == nil)
        let command = arguments.last ?? ""
        commands.withValue { $0.append(command) }
        if creationFails, command.contains("worktree"), command.contains("add") {
          throw ShellClientError(
            command: command, stdout: "", stderr: "Remote creation failed", exitCode: 1)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    }
    let pendingID: Worktree.ID = "pending:ssh-license-test"
    await store.send(
      .createWorktreeInRepository(
        repositoryID: repository.id, nameSource: .explicit("feature"),
        baseRefSource: .explicit("HEAD"), fetchOrigin: false,
        placement: WorktreePlacementOverride(path: "/home/me/worktrees"), pendingID: pendingID))
    if creationFails {
      let error = GitClientError.commandFailed(
        command:
          "/usr/bin/env git -C /home/me/repo worktree add /home/me/worktrees/feature/ -b feature HEAD",
        message: "stderr:\nRemote creation failed")
      await store.receive(\.worktreeCreationRejected) {
        $0.alert = AlertState {
          TextState("Unable to create worktree")
        } actions: {
          ButtonState(role: .cancel) { TextState("OK") }
        } message: {
          TextState(error.localizedDescription)
        }
      }
    } else {
      await store.receive(\.remoteWorktreeCreationCompleted)
      await store.receive(\.loadPersistedRepositories)
    }
    await store.finish()
    #expect(
      commands.value.contains {
        $0.contains("worktree") && $0.contains("/home/me/worktrees/feature")
      })
    #expect(licenseCalls.value == 0)
    #expect(stored.value.trialCreations == trialCreations)
    #expect(stored.value.pendingWorktreePaths == nil)
    #expect(store.state.licensePermits.isEmpty)
  }

  @Test func licenseDayFormatsAsItsOwnCalendarDay() throws {
    let locale = Locale(identifier: "en_US")
    #expect(try #require(LicenseDay("2026-03-01")).formatted(locale: locale) == "March 1, 2026")
    #expect(try #require(LicenseDay("2026-01-01")).formatted(locale: locale) == "January 1, 2026")
  }

  @Test(.dependencies) func ignoresActivationWithAnEmptyKey() async {
    let store = TestStore(initialState: LicenseFeature.State()) { LicenseFeature() }
    await store.send(.binding(.set(\.keyInput, "  "))) { $0.keyInput = "  " }
    await store.send(.activate)
  }

  @Test(.dependencies) func deactivateButtonDefersToTheSettingsConfirmation() async {
    let store = TestStore(initialState: LicenseFeature.State()) { LicenseFeature() }
    await store.send(.deactivateButtonTapped)
    await store.receive(\.delegate.deactivationRequested)
  }

  @Test(.dependencies) func deactivateButtonIsIgnoredWhileBusy() async {
    var state = LicenseFeature.State()
    state.isBusy = true
    let store = TestStore(initialState: state) { LicenseFeature() }
    await store.send(.deactivateButtonTapped)
  }

  @Test(.dependencies) func deactivationRunsOnlyAfterTheSettingsConfirmation() async {
    let storage = SettingsTestStorage()
    let deactivations = LockIsolated(0)
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0[LicenseClient.self].deactivate = {
        deactivations.withValue { $0 += 1 }
        return LicenseSnapshot()
      }
    } operation: {
      TestStore(initialState: AppFeature.State()) {
        AppFeature()
      }
    }

    await store.send(.license(.deactivateButtonTapped))
    await store.receive(\.license.delegate.deactivationRequested)
    await store.receive(\.settings.licenseDeactivationRequested) {
      $0.settings.alert = Self.deactivationAlert
    }
    #expect(store.state.license.alert == nil)
    await store.send(.settings(.alert(.dismiss))) {
      $0.settings.alert = nil
    }
    #expect(deactivations.value == 0)

    await store.send(.license(.deactivateButtonTapped))
    await store.receive(\.license.delegate.deactivationRequested)
    await store.receive(\.settings.licenseDeactivationRequested) {
      $0.settings.alert = Self.deactivationAlert
    }
    await store.send(.settings(.alert(.presented(.confirmLicenseDeactivation)))) {
      $0.settings.alert = nil
    }
    await store.receive(\.settings.delegate.deactivateLicense)
    await store.receive(\.license.deactivate) {
      $0.license.isBusy = true
    }
    await store.receive(\.license.completed.success) {
      $0.license.isBusy = false
    }
    #expect(deactivations.value == 1)
  }

  @Test(.dependencies) func deactivationRequestKeepsAnOpenSettingsAlert() async {
    var state = SettingsFeature.State()
    state.alert = AlertState { TextState("Open") }
    let store = TestStore(initialState: state) { SettingsFeature() }
    await store.send(.licenseDeactivationRequested)
  }

  private static var deactivationAlert: AlertState<SettingsFeature.Alert> {
    AlertState {
      TextState("Deactivate this Mac?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmLicenseDeactivation) {
        TextState("Deactivate")
      }
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("Cancel")
      }
    } message: {
      TextState("You can activate your license again on this Mac or another one with your key.")
    }
  }

  @Test func displayStatusReflectsTheEntitlement() throws {
    let through = try #require(LicenseDay("2026-08-01"))
    func snapshot(
      _ status: LicenseEntitlement.Status?, releaseDay: String? = "2026-07-01",
      updatesThrough: LicenseDay? = through, reason: String? = nil, isDevelopmentBuild: Bool = false
    ) -> LicenseSnapshot {
      LicenseSnapshot(
        entitlement: status.map {
          LicenseEntitlement(
            licenseID: "license", deviceID: "device", status: $0, updatesThrough: updatesThrough, revision: 1,
            issuedAt: 1, revocationReason: reason)
        },
        isDevelopmentBuild: isDevelopmentBuild,
        releaseDay: releaseDay.flatMap(LicenseDay.init(rawValue:))
      )
    }
    #expect(snapshot(nil).displayStatus == .notActivated)
    #expect(snapshot(nil, isDevelopmentBuild: true).displayStatus == .developmentBuild)
    #expect(snapshot(.active).displayStatus == .active)
    #expect(snapshot(.active, releaseDay: "2026-08-01").displayStatus == .active)
    #expect(snapshot(.active, releaseDay: "2026-08-02").displayStatus == .updatesExpired)
    // Statuses must agree with trial charging, which needs both days to own the release.
    #expect(snapshot(.active, releaseDay: nil).displayStatus == .updatesExpired)
    #expect(snapshot(.active, updatesThrough: nil).displayStatus == .updatesExpired)
    #expect(snapshot(.active, releaseDay: nil, isDevelopmentBuild: true).displayStatus == .active)
    #expect(snapshot(.revoked, reason: "Refunded").displayStatus == .revoked(reason: "Refunded"))
    #expect(snapshot(.revoked).displayStatus == .revoked(reason: nil))
    #expect(snapshot(.transferred).displayStatus == .transferred)
    #expect(snapshot(.deactivated).displayStatus == .deactivated)
  }

  @Test(.dependencies) func loadFailureDoesNotMaskAnInFlightRequest() async {
    var state = LicenseFeature.State()
    state.isBusy = true
    let store = TestStore(initialState: state) { LicenseFeature() }
    await store.send(.loaded(.failure(LicenseError.invalidKey)))
  }

  @Test(.dependencies) func activationLinkOpensLicenseSettingsAndActivates() async {
    let storage = SettingsTestStorage()
    let activatedKeys = LockIsolated<[String]>([])
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0[LicenseClient.self].activate = { key in
        activatedKeys.withValue { $0.append(key) }
        throw LicenseError.invalidKey
      }
    } operation: {
      TestStore(initialState: AppFeature.State()) {
        AppFeature()
      }
    }
    // The load and the activation race, so only their outcomes are asserted.
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.deeplink(.activateLicense(key: Self.key))) {
      $0.license.keyInput = Self.key
      $0.isSettingsWindowRequested = true
    }
    await store.receive(\.settings.setSelection) {
      $0.settings.selection = .license
    }
    await store.receive(\.license.load)
    await store.receive(\.license.activate) {
      $0.license.isBusy = true
    }
    await store.receive(\.license.completed.failure) {
      $0.license.isBusy = false
      $0.license.errorMessage = LicenseError.invalidKey.localizedDescription
    }
    #expect(activatedKeys.value == [Self.key])
    await store.send(.settingsWindowOpened) {
      $0.isSettingsWindowRequested = false
    }
  }

  @Test func activationLinksAreParsedAndRedacted() throws {
    let url = try #require(URL(string: "supacode://activate?key=\(Self.key)"))
    #expect(DeeplinkClient.liveValue.parse(url) == .activateLicense(key: Self.key))
    #expect(DeeplinkClient.loggingDescription(url) == "supacode://activate")
  }

  private nonisolated static func session(
    stored: LockIsolated<LicenseRecord>,
    publicKey: Data = Data(base64Encoded: LicenseBuild.publicKey)!,
    releaseDay: LicenseDay? = LicenseDay("2026-10-10"),
    isEnforced: Bool = true
  ) -> LicenseSession {
    LicenseSession(
      persistence: LicensePersistence(
        load: { stored.value }, save: { updated in stored.withValue { $0 = updated } }),
      device: Self.device, publicKey: publicKey, releaseDay: releaseDay, isEnforced: isEnforced,
      request: { _, _, _ in throw LicenseError.service("Offline") }
    )
  }

  private nonisolated static func token(
    signingKey: Curve25519.Signing.PrivateKey, updatesThrough: String = "2027-10-10",
    team: Bool = false, lease: Int64? = nil,
    status: String = "active", revision: Int = 1
  ) throws -> String {
    var claims: [String: Any] = [
      "v": team ? 2 : 1, "lid": String(repeating: "0", count: 32),
      "did": Self.device.id,
      "status": status, "rev": revision, "iat": 1,
    ]
    if status == "active" { claims["upd"] = updatesThrough }
    if status == "revoked" { claims["reason"] = "refund" }
    if team {
      claims["team"] = true
      claims["lease"] = lease
    }
    let payload = try JSONSerialization.data(withJSONObject: claims)
    let signature = try signingKey.signature(for: payload)
    return Self.base64URL(payload) + "." + Self.base64URL(signature)
  }

  private nonisolated static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing(
      "=", with: "")
  }
}
