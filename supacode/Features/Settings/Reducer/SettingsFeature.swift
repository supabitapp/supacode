import ComposableArchitecture
import Foundation

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
    var automaticallyArchiveMergedWorktrees: Bool
    var promptForWorktreeCreation: Bool
    var defaultWorktreeBaseDirectoryPath: String
    var selection: SettingsSection? = .general
    var repositorySettings: RepositorySettingsFeature.State?

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
      automaticallyArchiveMergedWorktrees = settings.automaticallyArchiveMergedWorktrees
      promptForWorktreeCreation = settings.promptForWorktreeCreation
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
        automaticallyArchiveMergedWorktrees: automaticallyArchiveMergedWorktrees,
        promptForWorktreeCreation: promptForWorktreeCreation,
        defaultWorktreeBaseDirectoryPath: SupacodePaths.normalizedWorktreeBaseDirectoryPath(
          defaultWorktreeBaseDirectoryPath
        )
      )
    }
  }

  enum Action: BindableAction {
    case task
    case settingsLoaded(GlobalSettings)
    case setSelection(SettingsSection?)
    case setSystemNotificationsEnabled(Bool)
    case repositorySettings(RepositorySettingsFeature.Action)
    case delegate(Delegate)
    case binding(BindingAction<State>)
  }

  @CasePathable
  enum Delegate: Equatable {
    case settingsChanged(GlobalSettings)
  }

  @Dependency(AnalyticsClient.self) private var analyticsClient

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
        state.automaticallyArchiveMergedWorktrees = normalizedSettings.automaticallyArchiveMergedWorktrees
        state.promptForWorktreeCreation = normalizedSettings.promptForWorktreeCreation
        state.defaultWorktreeBaseDirectoryPath = normalizedSettings.defaultWorktreeBaseDirectoryPath ?? ""
        return .send(.delegate(.settingsChanged(normalizedSettings)))

      case .binding:
        return persist(state)

      case .setSystemNotificationsEnabled(let isEnabled):
        state.systemNotificationsEnabled = isEnabled
        return persist(state)

      case .setSelection(let selection):
        state.selection = selection ?? .general
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
