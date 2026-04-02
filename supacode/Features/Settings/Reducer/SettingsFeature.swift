import ComposableArchitecture
import Foundation
import IdentifiedCollections

@Reducer
struct SettingsFeature {
  @ObservableState
  struct State: Equatable {
    var appearanceMode: AppearanceMode
    var defaultEditorID: String
    var confirmBeforeQuit: Bool
    var updateChannel: UpdateChannel
    var updatesAutomaticallyCheckForUpdates: Bool
    var updatesAutomaticallyDownloadUpdates: Bool
    var inAppNotificationsEnabled: Bool
    var notificationSoundEnabled: Bool
    var systemNotificationsEnabled: Bool
    var moveNotifiedWorktreeToTop: Bool
    var analyticsEnabled: Bool
    var crashReportsEnabled: Bool
    var githubIntegrationEnabled: Bool
    var deleteBranchOnDeleteWorktree: Bool
    var mergedWorktreeAction: MergedWorktreeAction?
    var promptForWorktreeCreation: Bool
    var fetchOriginBeforeWorktreeCreation: Bool
    var copyIgnoredOnWorktreeCreate: Bool
    var copyUntrackedOnWorktreeCreate: Bool
    var pullRequestMergeStrategy: PullRequestMergeStrategy
    var terminalThemeSyncEnabled: Bool
    var restoreTerminalLayoutEnabled: Bool
    var defaultWorktreeBaseDirectoryPath: String
    var autoDeleteArchivedWorktreesAfterDays: AutoDeletePeriod?
    var shortcutOverrides: [AppShortcutID: AppShortcutOverride]
    // nil = settings window closed, non-nil = open to this section.
    // The view layer opens the settings window when this becomes non-nil.
    var selection: SettingsSection?
    var sortedRepositoryIDs: [Repository.ID] = []
    var repositorySettings: RepositorySettingsFeature.State?
    @Presents var alert: AlertState<Alert>?

    init(settings: GlobalSettings = .default) {
      let normalizedDefaultEditorID = OpenWorktreeAction.normalizedDefaultEditorID(settings.defaultEditorID)
      appearanceMode = settings.appearanceMode
      defaultEditorID = normalizedDefaultEditorID
      confirmBeforeQuit = settings.confirmBeforeQuit
      updateChannel = settings.updateChannel
      updatesAutomaticallyCheckForUpdates = settings.updatesAutomaticallyCheckForUpdates
      updatesAutomaticallyDownloadUpdates = settings.updatesAutomaticallyDownloadUpdates
      inAppNotificationsEnabled = settings.inAppNotificationsEnabled
      notificationSoundEnabled = settings.notificationSoundEnabled
      systemNotificationsEnabled = settings.systemNotificationsEnabled
      moveNotifiedWorktreeToTop = settings.moveNotifiedWorktreeToTop
      analyticsEnabled = settings.analyticsEnabled
      crashReportsEnabled = settings.crashReportsEnabled
      githubIntegrationEnabled = settings.githubIntegrationEnabled
      deleteBranchOnDeleteWorktree = settings.deleteBranchOnDeleteWorktree
      mergedWorktreeAction = settings.mergedWorktreeAction
      promptForWorktreeCreation = settings.promptForWorktreeCreation
      fetchOriginBeforeWorktreeCreation = settings.fetchOriginBeforeWorktreeCreation
      copyIgnoredOnWorktreeCreate = settings.copyIgnoredOnWorktreeCreate
      copyUntrackedOnWorktreeCreate = settings.copyUntrackedOnWorktreeCreate
      pullRequestMergeStrategy = settings.pullRequestMergeStrategy
      terminalThemeSyncEnabled = settings.terminalThemeSyncEnabled
      restoreTerminalLayoutEnabled = settings.restoreTerminalLayoutEnabled
      autoDeleteArchivedWorktreesAfterDays = settings.autoDeleteArchivedWorktreesAfterDays
      shortcutOverrides = settings.shortcutOverrides
      defaultWorktreeBaseDirectoryPath =
        SupacodePaths.normalizedWorktreeBaseDirectoryPath(settings.defaultWorktreeBaseDirectoryPath) ?? ""
    }

    var globalSettings: GlobalSettings {
      GlobalSettings(
        appearanceMode: appearanceMode,
        defaultEditorID: defaultEditorID,
        confirmBeforeQuit: confirmBeforeQuit,
        updateChannel: updateChannel,
        updatesAutomaticallyCheckForUpdates: updatesAutomaticallyCheckForUpdates,
        updatesAutomaticallyDownloadUpdates: updatesAutomaticallyDownloadUpdates,
        inAppNotificationsEnabled: inAppNotificationsEnabled,
        notificationSoundEnabled: notificationSoundEnabled,
        systemNotificationsEnabled: systemNotificationsEnabled,
        moveNotifiedWorktreeToTop: moveNotifiedWorktreeToTop,
        analyticsEnabled: analyticsEnabled,
        crashReportsEnabled: crashReportsEnabled,
        githubIntegrationEnabled: githubIntegrationEnabled,
        deleteBranchOnDeleteWorktree: deleteBranchOnDeleteWorktree,
        mergedWorktreeAction: mergedWorktreeAction,
        promptForWorktreeCreation: promptForWorktreeCreation,
        fetchOriginBeforeWorktreeCreation: fetchOriginBeforeWorktreeCreation,
        copyIgnoredOnWorktreeCreate: copyIgnoredOnWorktreeCreate,
        copyUntrackedOnWorktreeCreate: copyUntrackedOnWorktreeCreate,
        pullRequestMergeStrategy: pullRequestMergeStrategy,
        terminalThemeSyncEnabled: terminalThemeSyncEnabled,
        restoreTerminalLayoutEnabled: restoreTerminalLayoutEnabled,
        defaultWorktreeBaseDirectoryPath: SupacodePaths.normalizedWorktreeBaseDirectoryPath(
          defaultWorktreeBaseDirectoryPath
        ),
        autoDeleteArchivedWorktreesAfterDays: autoDeleteArchivedWorktreesAfterDays,
        shortcutOverrides: shortcutOverrides
      )
    }
  }

  enum Action: BindableAction {
    case task
    case settingsLoaded(GlobalSettings)
    case repositoriesChanged(IdentifiedArrayOf<Repository>)
    case setSelection(SettingsSection?)
    case setSystemNotificationsEnabled(Bool)
    case showNotificationPermissionAlert(errorMessage: String?)
    case updateShortcut(id: AppShortcutID, override: AppShortcutOverride?)
    case toggleShortcutEnabled(id: AppShortcutID, enabled: Bool)
    case resetAllShortcuts
    case requestAutoDeleteDaysChange(AutoDeletePeriod?)
    case resolvedAutoDeleteAffectedCount(AutoDeletePeriod, affectedCount: Int)
    case repositorySettings(RepositorySettingsFeature.Action)
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)
    case binding(BindingAction<State>)
  }

  enum Alert: Equatable {
    case dismiss
    case openSystemNotificationSettings
    case confirmAutoDeleteDaysChange(AutoDeletePeriod)
  }

  @CasePathable
  enum Delegate: Equatable {
    case settingsChanged(GlobalSettings)
  }

  @Dependency(AnalyticsClient.self) private var analyticsClient
  @Dependency(RepositoryPersistenceClient.self) private var repositoryPersistence
  @Dependency(SystemNotificationClient.self) private var systemNotificationClient
  @Dependency(\.date.now) private var now

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        @Shared(.settingsFile) var settingsFile
        return .send(.settingsLoaded(settingsFile.global))

      case .settingsLoaded(let settings):
        let normalizedDefaultEditorID = OpenWorktreeAction.normalizedDefaultEditorID(settings.defaultEditorID)
        let normalizedWorktreeBaseDirPath =
          SupacodePaths.normalizedWorktreeBaseDirectoryPath(settings.defaultWorktreeBaseDirectoryPath)
        let normalizedSettings: GlobalSettings
        if normalizedDefaultEditorID == settings.defaultEditorID,
          normalizedWorktreeBaseDirPath == settings.defaultWorktreeBaseDirectoryPath
        {
          normalizedSettings = settings
        } else {
          var updatedSettings = settings
          updatedSettings.defaultEditorID = normalizedDefaultEditorID
          updatedSettings.defaultWorktreeBaseDirectoryPath = normalizedWorktreeBaseDirPath
          normalizedSettings = updatedSettings
          @Shared(.settingsFile) var settingsFile
          $settingsFile.withLock { $0.global = normalizedSettings }
        }
        state.appearanceMode = normalizedSettings.appearanceMode
        state.defaultEditorID = normalizedSettings.defaultEditorID
        state.confirmBeforeQuit = normalizedSettings.confirmBeforeQuit
        state.updateChannel = normalizedSettings.updateChannel
        state.updatesAutomaticallyCheckForUpdates = normalizedSettings.updatesAutomaticallyCheckForUpdates
        state.updatesAutomaticallyDownloadUpdates = normalizedSettings.updatesAutomaticallyDownloadUpdates
        state.inAppNotificationsEnabled = normalizedSettings.inAppNotificationsEnabled
        state.notificationSoundEnabled = normalizedSettings.notificationSoundEnabled
        state.systemNotificationsEnabled = normalizedSettings.systemNotificationsEnabled
        state.moveNotifiedWorktreeToTop = normalizedSettings.moveNotifiedWorktreeToTop
        state.analyticsEnabled = normalizedSettings.analyticsEnabled
        state.crashReportsEnabled = normalizedSettings.crashReportsEnabled
        state.githubIntegrationEnabled = normalizedSettings.githubIntegrationEnabled
        state.deleteBranchOnDeleteWorktree = normalizedSettings.deleteBranchOnDeleteWorktree
        state.mergedWorktreeAction = normalizedSettings.mergedWorktreeAction
        state.promptForWorktreeCreation = normalizedSettings.promptForWorktreeCreation
        state.fetchOriginBeforeWorktreeCreation = normalizedSettings.fetchOriginBeforeWorktreeCreation
        state.copyIgnoredOnWorktreeCreate = normalizedSettings.copyIgnoredOnWorktreeCreate
        state.copyUntrackedOnWorktreeCreate = normalizedSettings.copyUntrackedOnWorktreeCreate
        state.pullRequestMergeStrategy = normalizedSettings.pullRequestMergeStrategy
        state.terminalThemeSyncEnabled = normalizedSettings.terminalThemeSyncEnabled
        state.restoreTerminalLayoutEnabled = normalizedSettings.restoreTerminalLayoutEnabled
        state.autoDeleteArchivedWorktreesAfterDays = normalizedSettings.autoDeleteArchivedWorktreesAfterDays
        state.shortcutOverrides = normalizedSettings.shortcutOverrides
        state.defaultWorktreeBaseDirectoryPath = normalizedSettings.defaultWorktreeBaseDirectoryPath ?? ""
        state.syncGlobalDefaults(from: normalizedSettings)
        return .send(.delegate(.settingsChanged(normalizedSettings)))

      case .binding:
        state.syncGlobalDefaults(from: state.globalSettings)
        return persist(state)

      case .setSystemNotificationsEnabled(let isEnabled):
        state.systemNotificationsEnabled = isEnabled
        state.syncGlobalDefaults(from: state.globalSettings)
        return persist(state)

      case .showNotificationPermissionAlert(let errorMessage):
        let message: String
        if let errorMessage, !errorMessage.isEmpty {
          message =
            "Supacode cannot send system notifications.\n\n"
            + "Error: \(errorMessage)"
        } else {
          message = "Supacode cannot send system notifications while permission is denied."
        }
        state.alert = AlertState {
          TextState("Enable Notifications in System Settings")
        } actions: {
          ButtonState(action: .openSystemNotificationSettings) {
            TextState("Open System Settings")
          }
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("Cancel")
          }
        } message: {
          TextState(message)
        }
        return .none

      case .updateShortcut(let id, let override):
        if let override {
          state.shortcutOverrides[id] = override
        } else {
          state.shortcutOverrides.removeValue(forKey: id)
        }
        return persist(state)

      case .toggleShortcutEnabled(let id, let enabled):
        if enabled {
          // Re-enable: if override exists with a real binding, just flip the flag.
          // If it was a disabled sentinel, remove the override entirely (restore default).
          if var existing = state.shortcutOverrides[id] {
            existing.isEnabled = true
            if existing.keyCode == 0, existing.modifiers.isEmpty {
              state.shortcutOverrides.removeValue(forKey: id)
            } else {
              state.shortcutOverrides[id] = existing
            }
          }
        } else {
          if var existing = state.shortcutOverrides[id] {
            existing.isEnabled = false
            state.shortcutOverrides[id] = existing
          } else {
            state.shortcutOverrides[id] = .disabled
          }
        }
        return persist(state)

      case .resetAllShortcuts:
        state.shortcutOverrides = [:]
        return persist(state)

      case .requestAutoDeleteDaysChange(let newPeriod):
        // Apply immediately when safe (disabling or widening the window).
        // Otherwise, check if the new period would auto-delete existing worktrees.
        guard let newPeriod else {
          state.autoDeleteArchivedWorktreesAfterDays = nil
          return persist(state)
        }
        if let current = state.autoDeleteArchivedWorktreesAfterDays, newPeriod >= current {
          state.autoDeleteArchivedWorktreesAfterDays = newPeriod
          return persist(state)
        }
        // Check how many archived worktrees would be auto-deleted under the new period.
        return .run { [now] send in
          let archivedDates = await repositoryPersistence.loadArchivedWorktreeDates()
          let cutoff = now.addingTimeInterval(-Double(newPeriod.rawValue) * secondsPerDay)
          let affectedCount = archivedDates.values.filter { $0 <= cutoff }.count
          await send(.resolvedAutoDeleteAffectedCount(newPeriod, affectedCount: affectedCount))
        }

      case .resolvedAutoDeleteAffectedCount(let newPeriod, let affectedCount):
        guard affectedCount > 0 else {
          state.autoDeleteArchivedWorktreesAfterDays = newPeriod
          return persist(state)
        }
        let worktreeWord = affectedCount == 1 ? "worktree" : "worktrees"
        let pronoun = affectedCount == 1 ? "it was" : "they were"
        let dayWord = newPeriod == .oneDay ? "day" : "days"
        state.alert = AlertState {
          TextState("Delete \(affectedCount) archived \(worktreeWord)?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmAutoDeleteDaysChange(newPeriod)) {
            TextState("Delete")
          }
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("Cancel")
          }
        } message: {
          TextState(
            "\(affectedCount) archived \(worktreeWord) will be deleted immediately because "
              + "\(pronoun) archived more than \(newPeriod.rawValue) \(dayWord) ago."
          )
        }
        return .none

      case .alert(.presented(.confirmAutoDeleteDaysChange(let days))):
        state.alert = nil
        state.autoDeleteArchivedWorktreesAfterDays = days
        return persist(state)

      case .repositoriesChanged(let repositories):
        state.sortedRepositoryIDs =
          repositories
          .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
          .map(\.id)
        return .none

      case .setSelection(let selection):
        state.selection = selection
        return .none

      case .alert(.dismiss):
        state.alert = nil
        return .none

      case .alert(.presented(.openSystemNotificationSettings)):
        state.alert = nil
        return .run { _ in
          await systemNotificationClient.openSettings()
        }

      case .alert:
        return .none

      case .repositorySettings:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.repositorySettings, action: \.repositorySettings) {
      RepositorySettingsFeature()
    }
  }

  private func persist(_ state: State) -> Effect<Action> {
    let settings = state.globalSettings
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global = settings }
    if settings.analyticsEnabled {
      analyticsClient.capture("settings_changed", nil)
    }
    return .send(.delegate(.settingsChanged(settings)))
  }
}

extension SettingsFeature.State {
  mutating func syncGlobalDefaults(from settings: GlobalSettings) {
    repositorySettings?.globalDefaultWorktreeBaseDirectoryPath =
      settings.defaultWorktreeBaseDirectoryPath
    repositorySettings?.globalCopyIgnoredOnWorktreeCreate =
      settings.copyIgnoredOnWorktreeCreate
    repositorySettings?.globalCopyUntrackedOnWorktreeCreate =
      settings.copyUntrackedOnWorktreeCreate
    repositorySettings?.globalPullRequestMergeStrategy =
      settings.pullRequestMergeStrategy
  }
}
