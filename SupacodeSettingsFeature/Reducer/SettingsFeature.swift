import ComposableArchitecture
import Foundation
import Sharing
import SupacodeSettingsShared

@Reducer
public struct SettingsFeature {
  /// Lifecycle of the bundled `supacode` CLI install. Lives on the
  /// SettingsFeature state because that's the only owner; nesting keeps
  /// it out of the shared models package.
  public enum CLIInstallState: Equatable, Sendable {
    case checking
    case installed
    case notInstalled
    case installing
    case uninstalling
    case failed(String)

    public var isLoading: Bool {
      switch self {
      case .checking, .installing, .uninstalling: true
      default: false
      }
    }

    public var isInstalled: Bool {
      if case .installed = self { return true }
      return false
    }

    public var isFailure: Bool {
      if case .failed = self { return true }
      return false
    }

    public var errorMessage: String? {
      guard case .failed(let message) = self else { return nil }
      return message
    }
  }

  @ObservableState
  public struct State: Equatable {
    public var appearanceMode: AppearanceMode
    public var defaultEditorID: String
    public var updateChannel: UpdateChannel
    public var updatesAutomaticallyCheckForUpdates: Bool
    public var updatesAutomaticallyDownloadUpdates: Bool
    public var inAppNotificationsEnabled: Bool
    public var notificationSoundEnabled: Bool
    public var systemNotificationsEnabled: Bool
    public var moveNotifiedWorktreeToTop: Bool
    public var analyticsEnabled: Bool
    public var crashReportsEnabled: Bool
    public var githubIntegrationEnabled: Bool
    public var deleteBranchOnDeleteWorktree: Bool
    public var mergedWorktreeAction: MergedWorktreeAction?
    public var promptForWorktreeCreation: Bool
    public var fetchOriginBeforeWorktreeCreation: Bool
    public var copyIgnoredOnWorktreeCreate: Bool
    public var copyUntrackedOnWorktreeCreate: Bool
    public var pullRequestMergeStrategy: PullRequestMergeStrategy
    public var terminalThemeSyncEnabled: Bool
    public var hideSingleTabBar: Bool
    public var automatedActionPolicy: AutomatedActionPolicy
    public var defaultWorktreeBaseDirectoryPath: String
    public var autoDeleteArchivedWorktreesAfterDays: AutoDeletePeriod?
    public var shortcutOverrides: [AppShortcutID: AppShortcutOverride]
    public var globalScripts: [ScriptDefinition]
    public var richAgentNotificationsEnabled: Bool
    public var agentPresenceBadgesEnabled: Bool
    public var autoUpdateAgentIntegrationsEnabled: Bool
    public var confirmQuitMode: ConfirmQuitMode
    public var terminateSessionsOnQuit: Bool
    public var cliInstallState = CLIInstallState.checking
    /// Aggregate per-agent install state for the unified integration row.
    public var agentIntegrationStates: [SkillAgent: AgentIntegrationRowState] = [:]
    /// `nil` when the settings window is closed; non-nil selects the visible section.
    public var selection: SettingsSection?
    public var repositorySummaries: [SettingsRepositorySummary] = []
    public var repositorySettings: RepositorySettingsFeature.State?
    @Presents public var alert: AlertState<Alert>?

    public init(settings: GlobalSettings = .default) {
      let normalizedDefaultEditorID = OpenWorktreeAction.normalizedDefaultEditorID(settings.defaultEditorID)
      appearanceMode = settings.appearanceMode
      defaultEditorID = normalizedDefaultEditorID
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
      hideSingleTabBar = settings.hideSingleTabBar
      automatedActionPolicy = settings.automatedActionPolicy
      autoDeleteArchivedWorktreesAfterDays = settings.autoDeleteArchivedWorktreesAfterDays
      shortcutOverrides = settings.shortcutOverrides
      globalScripts = settings.globalScripts
      richAgentNotificationsEnabled = settings.richAgentNotificationsEnabled
      agentPresenceBadgesEnabled = settings.agentPresenceBadgesEnabled
      autoUpdateAgentIntegrationsEnabled = settings.autoUpdateAgentIntegrationsEnabled
      confirmQuitMode = settings.confirmQuitMode
      terminateSessionsOnQuit = settings.terminateSessionsOnQuit
      defaultWorktreeBaseDirectoryPath =
        SupacodePaths.normalizedWorktreeBaseDirectoryPath(settings.defaultWorktreeBaseDirectoryPath) ?? ""
    }

    var globalSettings: GlobalSettings {
      GlobalSettings(
        appearanceMode: appearanceMode,
        defaultEditorID: defaultEditorID,
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
        hideSingleTabBar: hideSingleTabBar,
        automatedActionPolicy: automatedActionPolicy,
        defaultWorktreeBaseDirectoryPath: SupacodePaths.normalizedWorktreeBaseDirectoryPath(
          defaultWorktreeBaseDirectoryPath
        ),
        autoDeleteArchivedWorktreesAfterDays: autoDeleteArchivedWorktreesAfterDays,
        shortcutOverrides: shortcutOverrides,
        globalScripts: globalScripts,
        richAgentNotificationsEnabled: richAgentNotificationsEnabled,
        agentPresenceBadgesEnabled: agentPresenceBadgesEnabled,
        autoUpdateAgentIntegrationsEnabled: autoUpdateAgentIntegrationsEnabled,
        confirmQuitMode: confirmQuitMode,
        terminateSessionsOnQuit: terminateSessionsOnQuit
      )
    }
  }

  public enum Action: BindableAction {
    case task
    case settingsLoaded(GlobalSettings)
    case repositoriesChanged([SettingsRepositorySummary])
    case setSelection(SettingsSection?)
    case setSystemNotificationsEnabled(Bool)
    case setAutomatedActionPolicy(AutomatedActionPolicy)
    case showNotificationPermissionAlert(errorMessage: String?)
    case updateShortcut(id: AppShortcutID, override: AppShortcutOverride?)
    case toggleShortcutEnabled(id: AppShortcutID, enabled: Bool)
    case resetAllShortcuts
    case requestAutoDeleteDaysChange(AutoDeletePeriod?)
    case resolvedAutoDeleteAffectedCount(AutoDeletePeriod, affectedCount: Int)
    case cliInstallChecked(installed: Bool)
    case cliInstallTapped
    case cliUninstallTapped
    case cliInstallCompleted(Result<Bool, Error>)
    case refreshAgentIntegrationStates
    case agentIntegrationChecked(SkillAgent, AgentIntegrationState)
    case agentIntegrationInstallTapped(SkillAgent)
    case agentIntegrationUninstallTapped(SkillAgent)
    case agentIntegrationCompleted(SkillAgent, Result<AgentIntegrationState, Error>)
    case repositorySettings(RepositorySettingsFeature.Action)
    case addGlobalScript
    case removeGlobalScript(ScriptDefinition.ID)
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)
    case binding(BindingAction<State>)
  }

  public enum Alert: Equatable {
    case dismiss
    case openSystemNotificationSettings
    case confirmAutoDeleteDaysChange(AutoDeletePeriod)
    case confirmRemoveGlobalScript(ScriptDefinition.ID)
  }

  @CasePathable
  public enum Delegate: Equatable {
    case settingsChanged(GlobalSettings)
  }

  @Dependency(AnalyticsClient.self) private var analyticsClient
  @Dependency(CLIInstallerClient.self) private var cliInstallerClient
  @Dependency(AgentIntegrationClient.self) private var agentIntegrationClient
  @Dependency(ArchivedWorktreeDatesClient.self) private var archivedWorktreeDatesClient
  @Dependency(SystemNotificationClient.self) private var systemNotificationClient
  @Dependency(\.date.now) private var now

  public init() {}

  public var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        @Shared(.settingsFile) var settingsFile
        return .concatenate(
          .send(.settingsLoaded(settingsFile.global)),
          .merge(
            .run { [cliInstallerClient] send in
              let installed = await cliInstallerClient.checkInstalled()
              await send(.cliInstallChecked(installed: installed))
            },
            .send(.refreshAgentIntegrationStates)
          )
        )

      case .refreshAgentIntegrationStates:
        // Cancellable so a stacked scene activation can't run two task
        // groups concurrently. Without this, two `.outdated` arrivals
        // can both dispatch `.agentIntegrationInstallTapped`, which
        // shares `AgentIntegrationCancelID` with the install effect and
        // would kill the first install mid-write.
        return .run { [agentIntegrationClient] send in
          await withTaskGroup(of: (SkillAgent, AgentIntegrationState).self) { group in
            for agent in SkillAgent.allCases {
              group.addTask { (agent, await agentIntegrationClient.state(agent)) }
            }
            for await (agent, integrationState) in group {
              await send(.agentIntegrationChecked(agent, integrationState))
            }
          }
        }
        .cancellable(id: RefreshAgentIntegrationStatesID(), cancelInFlight: true)

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
          normalizedSettings = persistGlobalSettingsPreservingRemoteRepositories(updatedSettings)
        }
        state.appearanceMode = normalizedSettings.appearanceMode
        state.defaultEditorID = normalizedSettings.defaultEditorID
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
        state.hideSingleTabBar = normalizedSettings.hideSingleTabBar
        state.automatedActionPolicy = normalizedSettings.automatedActionPolicy
        state.autoDeleteArchivedWorktreesAfterDays = normalizedSettings.autoDeleteArchivedWorktreesAfterDays
        state.shortcutOverrides = normalizedSettings.shortcutOverrides
        state.globalScripts = normalizedSettings.globalScripts
        state.richAgentNotificationsEnabled = normalizedSettings.richAgentNotificationsEnabled
        state.agentPresenceBadgesEnabled = normalizedSettings.agentPresenceBadgesEnabled
        state.autoUpdateAgentIntegrationsEnabled = normalizedSettings.autoUpdateAgentIntegrationsEnabled
        state.confirmQuitMode = normalizedSettings.confirmQuitMode
        state.terminateSessionsOnQuit = normalizedSettings.terminateSessionsOnQuit
        state.defaultWorktreeBaseDirectoryPath = normalizedSettings.defaultWorktreeBaseDirectoryPath ?? ""
        state.syncGlobalDefaults(from: normalizedSettings)
        synchronizeRepositorySelection(for: &state)
        return .send(.delegate(.settingsChanged(normalizedSettings)))

      case .binding:
        state.syncGlobalDefaults(from: state.globalSettings)
        return persist(state)

      case .setSystemNotificationsEnabled(let isEnabled):
        state.systemNotificationsEnabled = isEnabled
        state.syncGlobalDefaults(from: state.globalSettings)
        return persist(state)

      case .setAutomatedActionPolicy(let policy):
        state.automatedActionPolicy = policy
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

      case .cliInstallChecked(let installed):
        state.cliInstallState = installed ? .installed : .notInstalled
        return .none

      case .cliInstallTapped:
        guard !state.cliInstallState.isLoading else { return .none }
        state.cliInstallState = .installing
        return .run { [cliInstallerClient] send in
          do {
            try await cliInstallerClient.install()
            await send(.cliInstallCompleted(.success(true)))
          } catch {
            await send(.cliInstallCompleted(.failure(error)))
          }
        }

      case .cliUninstallTapped:
        guard !state.cliInstallState.isLoading else { return .none }
        state.cliInstallState = .uninstalling
        return .run { [cliInstallerClient] send in
          do {
            try await cliInstallerClient.uninstall()
            await send(.cliInstallCompleted(.success(false)))
          } catch {
            await send(.cliInstallCompleted(.failure(error)))
          }
        }

      case .cliInstallCompleted(.success(let installed)):
        state.cliInstallState = installed ? .installed : .notInstalled
        return .none

      case .cliInstallCompleted(.failure(let error)):
        // User cancelled the authorization dialog — restore the previous state.
        guard (error as? CLIInstallerError) != .cancelled else {
          let wasUninstalling = state.cliInstallState == .uninstalling
          state.cliInstallState = wasUninstalling ? .installed : .notInstalled
          return .none
        }
        state.cliInstallState = .failed(error.localizedDescription)
        return .none

      case .agentIntegrationChecked(let agent, let integrationState):
        // Don't clobber in-flight or failed states. `.installing` /
        // `.uninstalling` settle via `.agentIntegrationCompleted`;
        // overwriting them races the shared `AgentIntegrationCancelID`
        // (the auto-update branch below would otherwise cancel a
        // manual uninstall). `.failed` must survive so the error stays
        // visible and auto-update can't loop on a persistent failure.
        switch state.agentIntegrationStates[agent] {
        case .installing, .uninstalling, .failed: return .none
        default: break
        }
        state.agentIntegrationStates[agent] = .ready(integrationState)
        guard state.autoUpdateAgentIntegrationsEnabled, integrationState == .outdated
        else { return .none }
        return .send(.agentIntegrationInstallTapped(agent))

      case .agentIntegrationInstallTapped(let agent):
        state.agentIntegrationStates[agent] = .installing
        return .run { [agentIntegrationClient] send in
          do {
            try await agentIntegrationClient.install(agent)
            let next = await agentIntegrationClient.state(agent)
            await send(.agentIntegrationCompleted(agent, .success(next)))
          } catch {
            await send(.agentIntegrationCompleted(agent, .failure(error)))
          }
        }
        // Cancel an in-flight install for the same agent if Settings
        // is closed/reopened mid-flight — otherwise two effects could
        // race the same `~/.codex/hooks.json` read-modify-write.
        .cancellable(id: AgentIntegrationCancelID(agent: agent), cancelInFlight: true)

      case .agentIntegrationUninstallTapped(let agent):
        state.agentIntegrationStates[agent] = .uninstalling
        return .run { [agentIntegrationClient] send in
          do {
            try await agentIntegrationClient.uninstall(agent)
            let next = await agentIntegrationClient.state(agent)
            await send(.agentIntegrationCompleted(agent, .success(next)))
          } catch {
            await send(.agentIntegrationCompleted(agent, .failure(error)))
          }
        }
        .cancellable(id: AgentIntegrationCancelID(agent: agent), cancelInFlight: true)

      case .agentIntegrationCompleted(let agent, .success(let integrationState)):
        state.agentIntegrationStates[agent] = .ready(integrationState)
        return .none

      case .agentIntegrationCompleted(let agent, .failure(let error)):
        state.agentIntegrationStates[agent] = .failed(error.localizedDescription)
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
        // The timestamps come from the `archivedWorktreeDatesClient`
        // override wired in `supacodeApp`, which bridges the
        // canonical `@Shared(.sidebar)` archived bucket into this
        // package. Reading legacy `@Shared(.appStorage(...))` here
        // would silently return `[]` post-migration and let the
        // next reducer pass destroy everything older than the cutoff.
        let archivedDates = archivedWorktreeDatesClient.load()
        let cutoff = now.addingTimeInterval(-Double(newPeriod.rawValue) * secondsPerDay)
        let affectedCount = archivedDates.filter { $0 <= cutoff }.count
        return .send(.resolvedAutoDeleteAffectedCount(newPeriod, affectedCount: affectedCount))

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

      case .addGlobalScript:
        // Globals are always .custom; no kind picker needed.
        state.globalScripts.append(ScriptDefinition(kind: .custom))
        return persist(state)

      case .removeGlobalScript(let id):
        guard let script = state.globalScripts.first(where: { $0.id == id }) else { return .none }
        state.alert = AlertState {
          TextState("Remove \"\(script.displayName)\" script?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmRemoveGlobalScript(id)) {
            TextState("Remove")
          }
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("Cancel")
          }
        } message: {
          TextState(
            "This action cannot be undone. Any running instance keeps running in its terminal "
              + "tab until you close it manually."
          )
        }
        return .none

      case .alert(.presented(.confirmRemoveGlobalScript(let id))):
        state.alert = nil
        state.globalScripts.removeAll { $0.id == id }
        return persist(state)

      case .repositoriesChanged(let repositories):
        state.repositorySummaries =
          repositories
          .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        synchronizeRepositorySelection(for: &state)
        return .none

      case .setSelection(let selection):
        state.selection = selection
        synchronizeRepositorySelection(for: &state)
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
    let settings = persistGlobalSettingsPreservingRemoteRepositories(state.globalSettings)
    if settings.analyticsEnabled {
      analyticsClient.capture("settings_changed", nil)
    }
    return .send(.delegate(.settingsChanged(settings)))
  }

  @discardableResult
  private func persistGlobalSettingsPreservingRemoteRepositories(_ settings: GlobalSettings) -> GlobalSettings {
    var updatedSettings = settings
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      updatedSettings.remoteRepositories = $0.global.remoteRepositories
      $0.global = updatedSettings
    }
    return updatedSettings
  }

  private func synchronizeRepositorySelection(for state: inout State) {
    guard let selection = state.selection else {
      state.repositorySettings = nil
      return
    }
    guard let repositoryID = selection.repositoryID else {
      state.repositorySettings = nil
      return
    }
    guard let summary = state.repositorySummaries.first(where: { $0.id == repositoryID }) else {
      state.selection = .general
      state.repositorySettings = nil
      return
    }
    // Compare on host too: two remote hosts at the same path share a `rootURL`
    // but are distinct repositories, so a path-only check would keep stale state.
    if state.repositorySettings?.rootURL != summary.rootURL
      || state.repositorySettings?.host != summary.host
    {
      @Shared(.repositorySettings(summary.rootURL, host: summary.host)) var repositorySettings
      state.repositorySettings = RepositorySettingsFeature.State(
        rootURL: summary.rootURL,
        host: summary.host,
        isGitRepository: summary.isGitRepository,
        settings: repositorySettings
      )
    } else {
      // Summary can flip kind at runtime (git → folder or vice versa)
      // without the selection changing — keep the feature state in
      // sync so the scripts page picks the right render path.
      state.repositorySettings?.isGitRepository = summary.isGitRepository
    }
    state.syncGlobalDefaults(from: state.globalSettings)
  }
}

/// Cancellation key for in-flight integration install/uninstall effects so
/// the next tap (or a fresh Settings open) supersedes the prior one.
private nonisolated struct AgentIntegrationCancelID: Hashable, Sendable {
  let agent: SkillAgent
}

/// Cancellation key for the agent-state refresh effect so stacked scene
/// activations supersede the prior one. See `.refreshAgentIntegrationStates`.
private nonisolated struct RefreshAgentIntegrationStatesID: Hashable, Sendable {}

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
