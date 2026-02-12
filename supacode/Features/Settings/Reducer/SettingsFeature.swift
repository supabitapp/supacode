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
    var dockBadgeEnabled: Bool
    var notificationSoundEnabled: Bool
    var analyticsEnabled: Bool
    var crashReportsEnabled: Bool
    var githubIntegrationEnabled: Bool
    var deleteBranchOnDeleteWorktree: Bool
    var automaticallyArchiveMergedWorktrees: Bool
    var supacodeHomeDirectoryOverrideDraft = ""
    var supacodeHomeDirectoryValidationError: String?
    var isSupacodeHomeDirectoryRestartRequired = false
    var effectiveSupacodeHomeDirectoryPath = SupacodePaths.baseDirectory.path(percentEncoded: false)
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
      dockBadgeEnabled = settings.dockBadgeEnabled
      notificationSoundEnabled = settings.notificationSoundEnabled
      analyticsEnabled = settings.analyticsEnabled
      crashReportsEnabled = settings.crashReportsEnabled
      githubIntegrationEnabled = settings.githubIntegrationEnabled
      deleteBranchOnDeleteWorktree = settings.deleteBranchOnDeleteWorktree
      automaticallyArchiveMergedWorktrees = settings.automaticallyArchiveMergedWorktrees
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
        dockBadgeEnabled: dockBadgeEnabled,
        notificationSoundEnabled: notificationSoundEnabled,
        analyticsEnabled: analyticsEnabled,
        crashReportsEnabled: crashReportsEnabled,
        githubIntegrationEnabled: githubIntegrationEnabled,
        deleteBranchOnDeleteWorktree: deleteBranchOnDeleteWorktree,
        automaticallyArchiveMergedWorktrees: automaticallyArchiveMergedWorktrees
      )
    }
  }

  enum Action: BindableAction {
    case task
    case settingsLoaded(GlobalSettings)
    case supacodeHomeDirectoryDraftChanged(String)
    case applySupacodeHomeDirectoryOverride
    case resetSupacodeHomeDirectoryOverride
    case setSelection(SettingsSection?)
    case repositorySettings(RepositorySettingsFeature.Action)
    case delegate(Delegate)
    case binding(BindingAction<State>)
  }

  @CasePathable
  enum Delegate: Equatable {
    case settingsChanged(GlobalSettings)
  }

  @Dependency(\.analyticsClient) private var analyticsClient
  @Dependency(\.supacodeHomeOverridePersistence) private var supacodeHomeOverridePersistence

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        @Shared(.settingsFile) var settingsFile
        return .send(.settingsLoaded(settingsFile.global))

      case .settingsLoaded(let settings):
        let normalizedDefaultEditorID = OpenWorktreeAction.normalizedDefaultEditorID(settings.defaultEditorID)
        let normalizedSettings: GlobalSettings
        if normalizedDefaultEditorID == settings.defaultEditorID {
          normalizedSettings = settings
        } else {
          var updatedSettings = settings
          updatedSettings.defaultEditorID = normalizedDefaultEditorID
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
        state.dockBadgeEnabled = normalizedSettings.dockBadgeEnabled
        state.notificationSoundEnabled = normalizedSettings.notificationSoundEnabled
        state.analyticsEnabled = normalizedSettings.analyticsEnabled
        state.crashReportsEnabled = normalizedSettings.crashReportsEnabled
        state.githubIntegrationEnabled = normalizedSettings.githubIntegrationEnabled
        state.deleteBranchOnDeleteWorktree = normalizedSettings.deleteBranchOnDeleteWorktree
        state.automaticallyArchiveMergedWorktrees = normalizedSettings.automaticallyArchiveMergedWorktrees
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let persistedOverride = supacodeHomeOverridePersistence.load()
        if let persistedOverride,
          let normalizedPersistedOverride = SupacodePaths.normalizedBaseDirectoryOverride(
            persistedOverride,
            homeDirectory: homeDirectory
          )
        {
          state.supacodeHomeDirectoryOverrideDraft = normalizedPersistedOverride.path(percentEncoded: false)
        } else {
          state.supacodeHomeDirectoryOverrideDraft = ""
        }
        state.effectiveSupacodeHomeDirectoryPath = SupacodePaths.baseDirectory.path(percentEncoded: false)
        state.supacodeHomeDirectoryValidationError = nil
        state.isSupacodeHomeDirectoryRestartRequired = false
        return .send(.delegate(.settingsChanged(normalizedSettings)))

      case .supacodeHomeDirectoryDraftChanged(let draft):
        state.supacodeHomeDirectoryOverrideDraft = draft
        state.supacodeHomeDirectoryValidationError = nil
        return .none

      case .applySupacodeHomeDirectoryOverride:
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let trimmedDraft = state.supacodeHomeDirectoryOverrideDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else {
          supacodeHomeOverridePersistence.save(nil)
          state.supacodeHomeDirectoryOverrideDraft = ""
          state.supacodeHomeDirectoryValidationError = nil
          state.isSupacodeHomeDirectoryRestartRequired = true
          return .none
        }
        guard
          let normalizedOverride = SupacodePaths.normalizedBaseDirectoryOverride(
            trimmedDraft,
            homeDirectory: homeDirectory
          )
        else {
          state.supacodeHomeDirectoryValidationError = "Enter an absolute path, for example /tmp/supacode."
          return .none
        }
        let normalizedPath = normalizedOverride.path(percentEncoded: false)
        supacodeHomeOverridePersistence.save(normalizedPath)
        state.supacodeHomeDirectoryOverrideDraft = normalizedPath
        state.supacodeHomeDirectoryValidationError = nil
        state.isSupacodeHomeDirectoryRestartRequired = true
        return .none

      case .resetSupacodeHomeDirectoryOverride:
        supacodeHomeOverridePersistence.save(nil)
        state.supacodeHomeDirectoryOverrideDraft = ""
        state.supacodeHomeDirectoryValidationError = nil
        state.isSupacodeHomeDirectoryRestartRequired = true
        return .none

      case .binding:
        let settings = state.globalSettings
        @Shared(.settingsFile) var settingsFile
        $settingsFile.withLock { $0.global = settings }
        if settings.analyticsEnabled {
          analyticsClient.capture("settings_changed", nil)
        }
        return .send(.delegate(.settingsChanged(settings)))

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
}
