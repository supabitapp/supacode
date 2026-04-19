import Carbon.HIToolbox
import ComposableArchitecture
import CustomDump
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct SettingsFeatureTests {
  @Test(.dependencies) func loadSettings() async {
    let loaded = GlobalSettings(
      appearanceMode: .dark,
      defaultEditorID: OpenWorktreeAction.automaticSettingsID,
      confirmBeforeQuit: true,
      updateChannel: .stable,
      updatesAutomaticallyCheckForUpdates: false,
      updatesAutomaticallyDownloadUpdates: true,
      inAppNotificationsEnabled: false,
      notificationSoundEnabled: true,
      systemNotificationsEnabled: true,
      moveNotifiedWorktreeToTop: false,
      analyticsEnabled: false,
      crashReportsEnabled: true,
      githubIntegrationEnabled: true,
      deleteBranchOnDeleteWorktree: false,
      mergedWorktreeAction: .archive,
      promptForWorktreeCreation: true,
      terminalThemeSyncEnabled: false,
      automatedActionPolicy: .always,
    )
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = loaded }

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0[CLIInstallerClient.self].checkInstalled = { false }
      $0[CLISkillClient.self].checkInstalled = { _ in false }
      $0[ClaudeSettingsClient.self].checkInstalled = { _ in false }
      $0[CodexSettingsClient.self].checkInstalled = { _ in false }
    }

    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.task)
    await store.receive(\.settingsLoaded) {
      $0.appearanceMode = .dark
      $0.defaultEditorID = OpenWorktreeAction.automaticSettingsID
      $0.confirmBeforeQuit = true
      $0.updateChannel = .stable
      $0.updatesAutomaticallyCheckForUpdates = false
      $0.updatesAutomaticallyDownloadUpdates = true
      $0.inAppNotificationsEnabled = false
      $0.notificationSoundEnabled = true
      $0.moveNotifiedWorktreeToTop = false
      $0.systemNotificationsEnabled = true
      $0.analyticsEnabled = false
      $0.crashReportsEnabled = true
      $0.githubIntegrationEnabled = true
      $0.deleteBranchOnDeleteWorktree = false
      $0.mergedWorktreeAction = .archive
      $0.promptForWorktreeCreation = true
      $0.fetchOriginBeforeWorktreeCreation = true
      $0.terminalThemeSyncEnabled = false
      $0.automatedActionPolicy = .always
    }
    await store.skipReceivedActions()
    receiveStartupHookChecks(from: store)
  }

  @Test(.dependencies) func savesUpdatesChanges() async {
    let initialSettings = GlobalSettings(
      appearanceMode: .system,
      defaultEditorID: OpenWorktreeAction.automaticSettingsID,
      confirmBeforeQuit: true,
      updateChannel: .stable,
      updatesAutomaticallyCheckForUpdates: false,
      updatesAutomaticallyDownloadUpdates: false,
      inAppNotificationsEnabled: false,
      notificationSoundEnabled: false,
      systemNotificationsEnabled: false,
      moveNotifiedWorktreeToTop: true,
      analyticsEnabled: true,
      crashReportsEnabled: false,
      githubIntegrationEnabled: true,
      deleteBranchOnDeleteWorktree: true,
      mergedWorktreeAction: nil,
      promptForWorktreeCreation: false
    )
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    }

    await store.send(.binding(.set(\.appearanceMode, .light))) {
      $0.appearanceMode = .light
    }
    let expectedSettings = GlobalSettings(
      appearanceMode: .light,
      defaultEditorID: initialSettings.defaultEditorID,
      confirmBeforeQuit: initialSettings.confirmBeforeQuit,
      updateChannel: initialSettings.updateChannel,
      updatesAutomaticallyCheckForUpdates: initialSettings.updatesAutomaticallyCheckForUpdates,
      updatesAutomaticallyDownloadUpdates: initialSettings.updatesAutomaticallyDownloadUpdates,
      inAppNotificationsEnabled: initialSettings.inAppNotificationsEnabled,
      notificationSoundEnabled: initialSettings.notificationSoundEnabled,
      systemNotificationsEnabled: initialSettings.systemNotificationsEnabled,
      moveNotifiedWorktreeToTop: initialSettings.moveNotifiedWorktreeToTop,
      analyticsEnabled: initialSettings.analyticsEnabled,
      crashReportsEnabled: initialSettings.crashReportsEnabled,
      githubIntegrationEnabled: initialSettings.githubIntegrationEnabled,
      deleteBranchOnDeleteWorktree: initialSettings.deleteBranchOnDeleteWorktree,
      mergedWorktreeAction: initialSettings.mergedWorktreeAction,
      promptForWorktreeCreation: initialSettings.promptForWorktreeCreation
    )
    await store.receive(\.delegate.settingsChanged)

    expectNoDifference(settingsFile.global, expectedSettings)
  }

  @Test(.dependencies) func setSystemNotificationsEnabledPersistsChanges() async {
    var initialSettings = GlobalSettings.default
    initialSettings.systemNotificationsEnabled = false
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    }

    await store.send(.setSystemNotificationsEnabled(true)) {
      $0.systemNotificationsEnabled = true
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(settingsFile.global.systemNotificationsEnabled == true)
  }

  @Test(.dependencies) func selectionBuildsRepositorySettingsFromRepositorySummary() async {
    let summary = SettingsRepositorySummary(id: "/tmp/repo", name: "Repo")
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }

    await store.send(.repositoriesChanged([summary])) {
      $0.repositorySummaries = [summary]
    }

    await store.send(.setSelection(.repository(summary.id))) {
      $0.selection = .repository(summary.id)
      $0.repositorySettings = RepositorySettingsFeature.State(
        rootURL: summary.rootURL,
        settings: .default
      )
    }
  }

  @Test(.dependencies) func repositoriesChangedFlipsIsGitRepositoryWithoutRebuildingState() async {
    let summary = SettingsRepositorySummary(id: "/tmp/repo", name: "Repo", isGitRepository: true)
    let scriptsSelection = SettingsSection.repositoryScripts(summary.id)
    var initial = SettingsFeature.State()
    initial.selection = scriptsSelection
    initial.repositorySummaries = [summary]
    initial.repositorySettings = RepositorySettingsFeature.State(
      rootURL: summary.rootURL,
      isGitRepository: true,
      settings: .default
    )
    let store = TestStore(initialState: initial) {
      SettingsFeature()
    }

    // Same path, kind flipped git → folder: the feature state must
    // mutate in place so the scripts page picks the folder render
    // path without discarding the loaded `RepositorySettings`.
    let flipped = SettingsRepositorySummary(id: summary.id, name: summary.name, isGitRepository: false)
    await store.send(.repositoriesChanged([flipped])) {
      $0.repositorySummaries = [flipped]
      $0.repositorySettings?.isGitRepository = false
    }
  }

  @Test(.dependencies) func setSelectionNilClosesSettingsWindow() async {
    var state = SettingsFeature.State()
    state.selection = .general
    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.setSelection(nil)) {
      $0.selection = nil
    }
  }

  @Test(.dependencies) func loadingSettingsDoesNotResetSelection() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let selection = SettingsSection.repository(rootURL.path(percentEncoded: false))
    var state = SettingsFeature.State()
    state.selection = selection
    state.repositorySummaries = [
      SettingsRepositorySummary(id: rootURL.path(percentEncoded: false), name: "Repo")
    ]
    state.repositorySettings = RepositorySettingsFeature.State(
      rootURL: rootURL,
      settings: .default
    )
    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    let loaded = GlobalSettings(
      appearanceMode: .light,
      defaultEditorID: OpenWorktreeAction.automaticSettingsID,
      confirmBeforeQuit: false,
      updateChannel: .tip,
      updatesAutomaticallyCheckForUpdates: false,
      updatesAutomaticallyDownloadUpdates: true,
      inAppNotificationsEnabled: false,
      notificationSoundEnabled: false,
      systemNotificationsEnabled: true,
      moveNotifiedWorktreeToTop: true,
      analyticsEnabled: true,
      crashReportsEnabled: false,
      githubIntegrationEnabled: true,
      deleteBranchOnDeleteWorktree: true,
      mergedWorktreeAction: .archive,
      promptForWorktreeCreation: false
    )

    await store.send(.settingsLoaded(loaded)) {
      $0.appearanceMode = .light
      $0.defaultEditorID = OpenWorktreeAction.automaticSettingsID
      $0.confirmBeforeQuit = false
      $0.updateChannel = .tip
      $0.updatesAutomaticallyCheckForUpdates = false
      $0.updatesAutomaticallyDownloadUpdates = true
      $0.inAppNotificationsEnabled = false
      $0.notificationSoundEnabled = false
      $0.moveNotifiedWorktreeToTop = true
      $0.systemNotificationsEnabled = true
      $0.analyticsEnabled = true
      $0.crashReportsEnabled = false
      $0.githubIntegrationEnabled = true
      $0.deleteBranchOnDeleteWorktree = true
      $0.mergedWorktreeAction = .archive
      $0.promptForWorktreeCreation = false
      $0.selection = selection
      $0.repositorySummaries = [
        SettingsRepositorySummary(id: rootURL.path(percentEncoded: false), name: "Repo")
      ]
      $0.repositorySettings = RepositorySettingsFeature.State(
        rootURL: rootURL,
        settings: .default
      )
    }
    await store.receive(\.delegate.settingsChanged)
  }

  @Test(.dependencies) func settingsLoadedNormalizesDefaultWorktreeBaseDirectoryPath() async {
    var loaded = GlobalSettings.default
    loaded.defaultWorktreeBaseDirectoryPath = " ~/worktrees "
    let expectedPath = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "worktrees", directoryHint: .isDirectory)
      .standardizedFileURL
      .path(percentEncoded: false)
    let storage = SettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
    }

    await store.send(.settingsLoaded(loaded)) {
      $0.defaultWorktreeBaseDirectoryPath = expectedPath
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(store.state.defaultWorktreeBaseDirectoryPath == expectedPath)
  }

  @Test(.dependencies) func changingDefaultWorktreeBaseDirectoryUpdatesRepositorySettingsState() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let expectedPath = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "worktrees", directoryHint: .isDirectory)
      .standardizedFileURL
      .path(percentEncoded: false)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = .default }
    var state = SettingsFeature.State()
    state.repositorySettings = RepositorySettingsFeature.State(
      rootURL: rootURL,
      settings: .default
    )
    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.binding(.set(\.defaultWorktreeBaseDirectoryPath, " ~/worktrees "))) {
      $0.defaultWorktreeBaseDirectoryPath = " ~/worktrees "
      $0.repositorySettings?.globalDefaultWorktreeBaseDirectoryPath = expectedPath
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(store.state.repositorySettings?.globalDefaultWorktreeBaseDirectoryPath == expectedPath)
    #expect(settingsFile.global.defaultWorktreeBaseDirectoryPath == expectedPath)
  }

  @Test(.dependencies) func changingGlobalCopyIgnoredUpdatesRepositorySettingsState() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = .default }
    var state = SettingsFeature.State()
    state.repositorySettings = RepositorySettingsFeature.State(
      rootURL: rootURL,
      settings: .default
    )
    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.binding(.set(\.copyIgnoredOnWorktreeCreate, true))) {
      $0.copyIgnoredOnWorktreeCreate = true
      $0.repositorySettings?.globalCopyIgnoredOnWorktreeCreate = true
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(store.state.repositorySettings?.globalCopyIgnoredOnWorktreeCreate == true)
    #expect(settingsFile.global.copyIgnoredOnWorktreeCreate == true)
  }

  @Test(.dependencies) func changingGlobalMergeStrategyUpdatesRepositorySettingsState() async {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = .default }
    var state = SettingsFeature.State()
    state.repositorySettings = RepositorySettingsFeature.State(
      rootURL: rootURL,
      settings: .default
    )
    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.binding(.set(\.pullRequestMergeStrategy, .squash))) {
      $0.pullRequestMergeStrategy = .squash
      $0.repositorySettings?.globalPullRequestMergeStrategy = .squash
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(store.state.repositorySettings?.globalPullRequestMergeStrategy == .squash)
    #expect(settingsFile.global.pullRequestMergeStrategy == .squash)
  }

  @Test(.dependencies) func toggleRestoreTerminalLayoutPersists() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = .default }

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }

    await store.send(.binding(.set(\.restoreTerminalLayoutEnabled, true))) {
      $0.restoreTerminalLayoutEnabled = true
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(settingsFile.global.restoreTerminalLayoutEnabled == true)
  }

  // MARK: - Sorted repositories.

  @Test(.dependencies) func repositoriesChangedSortsByNameCaseInsensitive() async {
    let repoC = SettingsRepositorySummary(id: "/tmp/charlie", name: "Charlie")
    let repoA = SettingsRepositorySummary(id: "/tmp/alpha", name: "alpha")
    let repoB = SettingsRepositorySummary(id: "/tmp/bravo", name: "Bravo")

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }

    await store.send(.repositoriesChanged([repoC, repoA, repoB])) {
      $0.repositorySummaries = [repoA, repoB, repoC]
    }
  }

  @Test(.dependencies) func repositoriesChangedClearsMissingRepositorySelection() async {
    let summary = SettingsRepositorySummary(id: "/tmp/repo", name: "Repo")
    var state = SettingsFeature.State()
    state.selection = .repository(summary.id)
    state.repositorySummaries = [summary]
    state.repositorySettings = RepositorySettingsFeature.State(
      rootURL: summary.rootURL,
      settings: .default
    )
    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.repositoriesChanged([])) {
      $0.selection = .general
      $0.repositorySummaries = []
      $0.repositorySettings = nil
    }
  }

  @Test(.dependencies) func setSelectionToNonRepositoryClearsRepositorySettings() async {
    let summary = SettingsRepositorySummary(id: "/tmp/repo", name: "Repo")
    var state = SettingsFeature.State()
    state.selection = .repository(summary.id)
    state.repositorySummaries = [summary]
    state.repositorySettings = RepositorySettingsFeature.State(
      rootURL: summary.rootURL,
      settings: .default
    )
    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.setSelection(.general)) {
      $0.selection = .general
      $0.repositorySettings = nil
    }
  }

  // MARK: - Keyboard shortcut overrides.

  @Test(.dependencies) func updateShortcutPersistsOverride() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = .default }

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }

    let override = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command])
    await store.send(.updateShortcut(id: .newWorktree, override: override)) {
      $0.shortcutOverrides[.newWorktree] = override
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(settingsFile.global.shortcutOverrides[.newWorktree] == override)
  }

  @Test(.dependencies) func updateShortcutRemovesOverride() async {
    let override = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command])
    var initialSettings = GlobalSettings.default
    initialSettings.shortcutOverrides = [.newWorktree: override]
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    }

    await store.send(.updateShortcut(id: .newWorktree, override: nil)) {
      $0.shortcutOverrides.removeValue(forKey: .newWorktree)
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(settingsFile.global.shortcutOverrides[.newWorktree] == nil)
  }

  @Test(.dependencies) func resetAllShortcutsClearsOverrides() async {
    let override = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command])
    var initialSettings = GlobalSettings.default
    initialSettings.shortcutOverrides = [
      .newWorktree: override,
      .openSettings: override,
    ]
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    }

    await store.send(.resetAllShortcuts) {
      $0.shortcutOverrides = [:]
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(settingsFile.global.shortcutOverrides.isEmpty)
  }

  // MARK: - Toggle shortcut enabled.

  @Test(.dependencies) func toggleShortcutDisabledInsertsDisabledSentinel() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = .default }

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }

    await store.send(.toggleShortcutEnabled(id: .newWorktree, enabled: false)) {
      $0.shortcutOverrides[.newWorktree] = .disabled
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(settingsFile.global.shortcutOverrides[.newWorktree] == .disabled)
  }

  @Test(.dependencies) func toggleShortcutDisabledWithExistingOverrideFlipsFlag() async {
    let override = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command])
    var initialSettings = GlobalSettings.default
    initialSettings.shortcutOverrides = [.newWorktree: override]
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    }

    let expected = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command], isEnabled: false)
    await store.send(.toggleShortcutEnabled(id: .newWorktree, enabled: false)) {
      $0.shortcutOverrides[.newWorktree] = expected
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(settingsFile.global.shortcutOverrides[.newWorktree] == expected)
  }

  @Test(.dependencies) func toggleShortcutEnabledRemovesDisabledSentinel() async {
    var initialSettings = GlobalSettings.default
    initialSettings.shortcutOverrides = [.newWorktree: .disabled]
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    }

    await store.send(.toggleShortcutEnabled(id: .newWorktree, enabled: true)) {
      $0.shortcutOverrides.removeValue(forKey: .newWorktree)
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(settingsFile.global.shortcutOverrides[.newWorktree] == nil)
  }

  @Test(.dependencies) func toggleShortcutEnabledReEnablesCustomOverride() async {
    let override = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command], isEnabled: false)
    var initialSettings = GlobalSettings.default
    initialSettings.shortcutOverrides = [.newWorktree: override]
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = initialSettings }

    let store = TestStore(initialState: SettingsFeature.State(settings: initialSettings)) {
      SettingsFeature()
    }

    let expected = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command], isEnabled: true)
    await store.send(.toggleShortcutEnabled(id: .newWorktree, enabled: true)) {
      $0.shortcutOverrides[.newWorktree] = expected
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(settingsFile.global.shortcutOverrides[.newWorktree] == expected)
  }

  // MARK: - Settings loaded includes overrides.

  @Test(.dependencies) func settingsLoadedIncludesShortcutOverrides() async {
    let override = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command])
    var loaded = GlobalSettings.default
    loaded.shortcutOverrides = [.openSettings: override]
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = loaded }

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0[CLIInstallerClient.self].checkInstalled = { false }
      $0[CLISkillClient.self].checkInstalled = { _ in false }
      $0[ClaudeSettingsClient.self].checkInstalled = { _ in false }
      $0[CodexSettingsClient.self].checkInstalled = { _ in false }
    }

    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.task)
    await store.receive(\.settingsLoaded) {
      $0.shortcutOverrides = [.openSettings: override]
    }
    await store.skipReceivedActions()
    receiveStartupHookChecks(from: store)
  }

  // MARK: - Auto-Delete Archived Worktrees Setting

  @Test(.dependencies) func requestAutoDeleteDaysChangeDisablingAppliesImmediately() async {
    var settings = GlobalSettings.default
    settings.autoDeleteArchivedWorktreesAfterDays = .sevenDays
    let store = TestStore(initialState: SettingsFeature.State(settings: settings)) {
      SettingsFeature()
    }

    await store.send(.requestAutoDeleteDaysChange(nil)) {
      $0.autoDeleteArchivedWorktreesAfterDays = nil
    }
    await store.receive(\.delegate.settingsChanged)
  }

  @Test(.dependencies) func requestAutoDeleteDaysChangeIncreasingAppliesImmediately() async {
    var settings = GlobalSettings.default
    settings.autoDeleteArchivedWorktreesAfterDays = .sevenDays
    let store = TestStore(initialState: SettingsFeature.State(settings: settings)) {
      SettingsFeature()
    }

    await store.send(.requestAutoDeleteDaysChange(.fourteenDays)) {
      $0.autoDeleteArchivedWorktreesAfterDays = .fourteenDays
    }
    await store.receive(\.delegate.settingsChanged)
  }

  @Test(.dependencies) func requestAutoDeleteDaysChangeShorteningShowsAlertWhenAffected() async {
    var settings = GlobalSettings.default
    settings.autoDeleteArchivedWorktreesAfterDays = .fourteenDays
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let tenDaysAgo = fixedDate.addingTimeInterval(-10 * 86400)
    let store = TestStore(initialState: SettingsFeature.State(settings: settings)) {
      SettingsFeature()
    }
    store.dependencies.date = .constant(fixedDate)
    store.dependencies.archivedWorktreeDatesClient = ArchivedWorktreeDatesClient(
      load: { [tenDaysAgo] },
    )

    await store.send(.requestAutoDeleteDaysChange(.sevenDays))
    await store.receive(\.resolvedAutoDeleteAffectedCount) {
      $0.alert = AlertState {
        TextState("Delete 1 archived worktree?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmAutoDeleteDaysChange(.sevenDays)) {
          TextState("Delete")
        }
        ButtonState(role: .cancel, action: .dismiss) {
          TextState("Cancel")
        }
      } message: {
        TextState(
          "1 archived worktree will be deleted immediately because "
            + "it was archived more than 7 days ago."
        )
      }
    }
  }

  @Test(.dependencies) func requestAutoDeleteDaysChangeShorteningNoAffectedAppliesImmediately() async {
    var settings = GlobalSettings.default
    settings.autoDeleteArchivedWorktreesAfterDays = .fourteenDays
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let oneDayAgo = fixedDate.addingTimeInterval(-1 * 86400)
    let store = TestStore(initialState: SettingsFeature.State(settings: settings)) {
      SettingsFeature()
    }
    store.dependencies.date = .constant(fixedDate)
    store.dependencies.archivedWorktreeDatesClient = ArchivedWorktreeDatesClient(
      load: { [oneDayAgo] },
    )

    await store.send(.requestAutoDeleteDaysChange(.sevenDays))
    await store.receive(\.resolvedAutoDeleteAffectedCount) {
      $0.autoDeleteArchivedWorktreesAfterDays = .sevenDays
    }
    await store.receive(\.delegate.settingsChanged)
  }

  @Test(.dependencies) func confirmAutoDeleteDaysChangeAppliesSetting() async {
    var settings = GlobalSettings.default
    settings.autoDeleteArchivedWorktreesAfterDays = .fourteenDays
    var state = SettingsFeature.State(settings: settings)
    state.alert = AlertState {
      TextState("Delete 1 archived worktree?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmAutoDeleteDaysChange(.threeDays)) {
        TextState("Delete")
      }
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("Cancel")
      }
    } message: {
      TextState("placeholder")
    }
    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.alert(.presented(.confirmAutoDeleteDaysChange(.threeDays)))) {
      $0.alert = nil
      $0.autoDeleteArchivedWorktreesAfterDays = .threeDays
    }
    await store.receive(\.delegate.settingsChanged)
  }

  @Test(.dependencies) func requestAutoDeleteDaysChangeShorteningShowsAlertWithPluralWording() async {
    var settings = GlobalSettings.default
    settings.autoDeleteArchivedWorktreesAfterDays = .fourteenDays
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let tenDaysAgo = fixedDate.addingTimeInterval(-10 * 86400)
    let twelveDaysAgo = fixedDate.addingTimeInterval(-12 * 86400)
    let store = TestStore(initialState: SettingsFeature.State(settings: settings)) {
      SettingsFeature()
    }
    store.dependencies.date = .constant(fixedDate)
    store.dependencies.archivedWorktreeDatesClient = ArchivedWorktreeDatesClient(
      load: { [tenDaysAgo, twelveDaysAgo] },
    )

    await store.send(.requestAutoDeleteDaysChange(.sevenDays))
    await store.receive(\.resolvedAutoDeleteAffectedCount) {
      $0.alert = AlertState {
        TextState("Delete 2 archived worktrees?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmAutoDeleteDaysChange(.sevenDays)) {
          TextState("Delete")
        }
        ButtonState(role: .cancel, action: .dismiss) {
          TextState("Cancel")
        }
      } message: {
        TextState(
          "2 archived worktrees will be deleted immediately because "
            + "they were archived more than 7 days ago."
        )
      }
    }
  }

  @Test(.dependencies) func requestAutoDeleteDaysChangeCancelKeepsPreviousSetting() async {
    var settings = GlobalSettings.default
    settings.autoDeleteArchivedWorktreesAfterDays = .fourteenDays
    var state = SettingsFeature.State(settings: settings)
    state.alert = AlertState {
      TextState("Delete 1 archived worktree?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmAutoDeleteDaysChange(.sevenDays)) {
        TextState("Delete")
      }
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("Cancel")
      }
    } message: {
      TextState("placeholder")
    }
    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.alert(.dismiss)) {
      $0.alert = nil
    }
    // No settingsChanged delegate emitted — setting stays at .fourteenDays.
  }

  @Test(.dependencies) func requestAutoDeleteDaysChangeEnablingChecksAffectedCount() async {
    // Use a very old date so that leaked @Shared state from other tests
    // (with normal-range dates) falls outside the cutoff and is not counted.
    let fixedDate = Date.distantPast
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }
    store.dependencies.date = .constant(fixedDate)
    store.dependencies.archivedWorktreeDatesClient = ArchivedWorktreeDatesClient(
      load: { [] },
    )

    await store.send(.requestAutoDeleteDaysChange(.sevenDays))
    await store.receive(\.resolvedAutoDeleteAffectedCount) {
      $0.autoDeleteArchivedWorktreesAfterDays = .sevenDays
    }
    await store.receive(\.delegate.settingsChanged)
  }

  /// Regression test for C7: after the sidebar refactor, the
  /// auto-delete preflight used to read timestamps from the legacy
  /// `@Shared(.appStorage("archivedWorktreeDates"))` dict via
  /// `ArchivedWorktreeDatesClient.liveValue`. The sidebar migrator
  /// wipes that key on first launch, so the affected count would
  /// drop to 0, the destructive-confirmation alert would silently
  /// skip, and the next reducer pass would read from the new
  /// `@Shared(.sidebar)` and delete everything older than the
  /// cutoff without user consent. The fix routes the affected
  /// count through the same canonical `@Shared(.sidebar)` source
  /// the sweep reads from — so if timestamps exist they surface
  /// in the alert, and if they don't no alert is skipped-past.
  @Test(.dependencies)
  func requestAutoDeleteDaysChangeReadsTimestampsFromCanonicalSidebarBucket() async {
    var settings = GlobalSettings.default
    settings.autoDeleteArchivedWorktreesAfterDays = .fourteenDays
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let thirtyDaysAgoA = fixedDate.addingTimeInterval(-30 * 86400)
    let thirtyDaysAgoB = fixedDate.addingTimeInterval(-31 * 86400)
    let thirtyDaysAgoC = fixedDate.addingTimeInterval(-32 * 86400)
    let store = TestStore(initialState: SettingsFeature.State(settings: settings)) {
      SettingsFeature()
    }
    store.dependencies.date = .constant(fixedDate)
    store.dependencies.archivedWorktreeDatesClient = ArchivedWorktreeDatesClient(
      load: { [thirtyDaysAgoA, thirtyDaysAgoB, thirtyDaysAgoC] },
    )

    await store.send(.requestAutoDeleteDaysChange(.sevenDays))
    // The period must NOT be mutated pre-confirmation — otherwise
    // the destructive change silently races the next sweep.
    #expect(store.state.autoDeleteArchivedWorktreesAfterDays == .fourteenDays)
    await store.receive(\.resolvedAutoDeleteAffectedCount) {
      $0.alert = AlertState {
        TextState("Delete 3 archived worktrees?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmAutoDeleteDaysChange(.sevenDays)) {
          TextState("Delete")
        }
        ButtonState(role: .cancel, action: .dismiss) {
          TextState("Cancel")
        }
      } message: {
        TextState(
          "3 archived worktrees will be deleted immediately because "
            + "they were archived more than 7 days ago."
        )
      }
    }
    #expect(store.state.autoDeleteArchivedWorktreesAfterDays == .fourteenDays)
  }

  // MARK: - GlobalSettings Decoding Validation

  #if DEBUG
    @Test func decodingAutoDeleteAcceptsZeroInDebug() throws {
      let json = try makeGlobalSettingsJSON(autoDeleteDays: 0)
      let settings = try JSONDecoder().decode(GlobalSettings.self, from: json)
      #expect(settings.autoDeleteArchivedWorktreesAfterDays == .immediately)
    }
  #else
    @Test func decodingAutoDeleteRejectsZero() throws {
      let json = try makeGlobalSettingsJSON(autoDeleteDays: 0)
      let settings = try JSONDecoder().decode(GlobalSettings.self, from: json)
      #expect(settings.autoDeleteArchivedWorktreesAfterDays == nil)
    }
  #endif

  @Test func decodingAutoDeleteRejectsNegative() throws {
    let json = try makeGlobalSettingsJSON(autoDeleteDays: -5)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: json)
    #expect(settings.autoDeleteArchivedWorktreesAfterDays == nil)
  }

  @Test func decodingAutoDeleteRejectsUnrecognizedPositive() throws {
    let json = try makeGlobalSettingsJSON(autoDeleteDays: 99)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: json)
    #expect(settings.autoDeleteArchivedWorktreesAfterDays == nil)
  }

  @Test func decodingAutoDeleteAcceptsValidPeriod() throws {
    let json = try makeGlobalSettingsJSON(autoDeleteDays: 7)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: json)
    #expect(settings.autoDeleteArchivedWorktreesAfterDays == .sevenDays)
  }

  private func makeGlobalSettingsJSON(autoDeleteDays: Int) throws -> Data {
    let base = GlobalSettings.default
    let encoded = try JSONEncoder().encode(base)
    var dict = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
    dict["autoDeleteArchivedWorktreesAfterDays"] = autoDeleteDays
    return try JSONSerialization.data(withJSONObject: dict)
  }

  // MARK: - AutomatedActionPolicy migration.

  @Test func decodingNewPolicyFieldIsUsed() throws {
    let json = try makeGlobalSettingsJSONWithPolicy(policy: "never")
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: json)
    #expect(settings.automatedActionPolicy == .never)
  }

  @Test func decodingLegacyBoolTrueMigratedToAlways() throws {
    let json = try makeGlobalSettingsJSONWithLegacyBool(true)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: json)
    #expect(settings.automatedActionPolicy == .always)
  }

  @Test func decodingLegacyBoolFalseMigratedToNever() throws {
    let json = try makeGlobalSettingsJSONWithLegacyBool(false)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: json)
    #expect(settings.automatedActionPolicy == .never)
  }

  @Test func decodingNeitherFieldUsesDefault() throws {
    let json = try makeGlobalSettingsJSONWithoutPolicy()
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: json)
    #expect(settings.automatedActionPolicy == GlobalSettings.default.automatedActionPolicy)
  }

  private func makeGlobalSettingsJSONWithPolicy(policy: String) throws -> Data {
    let base = GlobalSettings.default
    let encoded = try JSONEncoder().encode(base)
    var dict = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
    dict["automatedActionPolicy"] = policy
    return try JSONSerialization.data(withJSONObject: dict)
  }

  private func makeGlobalSettingsJSONWithLegacyBool(_ value: Bool) throws -> Data {
    let base = GlobalSettings.default
    let encoded = try JSONEncoder().encode(base)
    var dict = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
    dict.removeValue(forKey: "automatedActionPolicy")
    dict["allowArbitraryDeeplinkInput"] = value
    return try JSONSerialization.data(withJSONObject: dict)
  }

  private func makeGlobalSettingsJSONWithoutPolicy() throws -> Data {
    let base = GlobalSettings.default
    let encoded = try JSONEncoder().encode(base)
    var dict = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
    dict.removeValue(forKey: "automatedActionPolicy")
    dict.removeValue(forKey: "allowArbitraryDeeplinkInput")
    return try JSONSerialization.data(withJSONObject: dict)
  }
}

@MainActor
private func receiveStartupHookChecks(from store: TestStoreOf<SettingsFeature>) {
  // CLI/skill/hook checks run in parallel via .merge.
  // Caller must drain effects before calling this. Assert final state only.
  #expect(store.state.cliInstallState == .notInstalled)
  #expect(store.state.claudeSkillState == .notInstalled)
  #expect(store.state.codexSkillState == .notInstalled)
  #expect(store.state.claudeProgressState == .notInstalled)
  #expect(store.state.claudeNotificationsState == .notInstalled)
  #expect(store.state.codexProgressState == .notInstalled)
  #expect(store.state.codexNotificationsState == .notInstalled)
}
