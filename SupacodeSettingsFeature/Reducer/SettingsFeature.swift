import ComposableArchitecture
import Foundation
import Sharing
import SupacodeSettingsShared

private nonisolated let settingsFeatureLogger = SupaLogger("Settings")

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
    /// Kept raw, never normalized against `installedOpenActions`. Any settings write
    /// persists this, so folding an uninstalled editor down to "auto" would write that
    /// fallback to disk and lose the user's choice even if they reinstall. Readers
    /// normalize against `installed` instead.
    public var defaultEditorID: String
    public var updateChannel: UpdateChannel
    public var updatesAutomaticallyCheckForUpdates: Bool
    public var updatesAutomaticallyDownloadUpdates: Bool
    public var inAppNotificationsEnabled: Bool
    public var notificationSound: NotificationSound
    public var systemNotificationsEnabled: Bool
    public var muteNotificationsForActiveSurface: Bool
    public var moveNotifiedWorktreeToTop: Bool
    public var notificationRetentionLimit: NotificationRetentionLimit
    public var analyticsEnabled: Bool
    public var crashReportsEnabled: Bool
    public var githubIntegrationEnabled: Bool
    public var gitlabIntegrationEnabled: Bool
    public var deleteBranchOnDeleteWorktree: Bool
    public var mergedWorktreeAction: MergedWorktreeAction
    public var promptForWorktreeCreation: Bool
    public var fetchOriginBeforeWorktreeCreation: Bool
    public var copyIgnoredOnWorktreeCreate: Bool
    public var copyUntrackedOnWorktreeCreate: Bool
    public var pullRequestMergeStrategy: PullRequestMergeStrategy
    public var terminalThemeSyncEnabled: Bool
    public var ghosttyUserConfigMode: GhosttyUserConfigMode
    public var automatedActionPolicy: AutomatedActionPolicy
    public var defaultWorktreeBaseDirectoryPath: String
    public var autoDeleteArchivedWorktreesAfterDays: AutoDeletePeriod?
    public var shortcutOverrides: [AppShortcutID: AppShortcutOverride]
    public var globalScripts: [ScriptDefinition]
    public var openFileScript: String
    public var richAgentNotificationsEnabled: Bool
    public var agentPresenceBadgesEnabled: Bool
    public var confirmQuitMode: ConfirmQuitMode
    public var confirmCloseSurface: Bool
    public var confirmCloseTab: ConfirmCloseTabMode
    public var terminateSessionsOnQuit: Bool
    public var remoteSessionPersistenceEnabled: Bool
    public var appVisibility: AppVisibility
    public var terminalHibernationEnabled: Bool
    public var chromeTextSize: ChromeTextSize
    public var automaticRepositoryRefreshEnabled: Bool
    public var automaticRepositoryRefreshInterval: Int
    public var hoverFocusMode: HoverFocusMode
    public var globalToggleVisibilityHotkey: AppShortcutOverride?
    /// True when the last registration of the global hotkey failed (chord
    /// unavailable). Transient UI state, never persisted.
    public var globalHotkeyRegistrationFailed = false
    public var cliInstallState = CLIInstallState.checking
    /// Installed editors in menu order, resolved once off the picker's body.
    public var installedOpenActions: [OpenWorktreeAction]
    /// Per-install row state, keyed by target (agent + location) so two installs
    /// of one agent into different folders never share a row.
    public var agentIntegrationStates: [AgentInstallTarget: AgentIntegrationRowState] = [:]
    /// Targets auto-updated this session, recorded directly so no intermediate
    /// row state can make the once-per-session guard forget. Keyed by target so a
    /// custom folder's heal never consumes the default's. A manual tap never reads it.
    public var autoInstalledTargets: Set<AgentInstallTarget> = []
    /// Targets whose config directory exists on disk, resolved by the probe, so
    /// the Finder-link affordance never stats in a view body.
    public var configDirectoriesOnDisk: Set<AgentInstallTarget> = []
    /// True while the install-more-agents modal is presented. Opening is gated
    /// in the reducer (`agentInstallSheetOpenTapped`) so the sheet is never
    /// reachable empty.
    public var agentInstallSheetPresented = false
    /// `nil` when the settings window is closed; non-nil selects the visible section.
    public var selection: SettingsSection?
    public var repositorySummaries: [SettingsRepositorySummary] = []
    public var repositorySettings: RepositorySettingsFeature.State?
    @Presents public var alert: AlertState<Alert>?

    /// True when at least one notification delivery channel (macOS banner or
    /// the fallback sound) can fire, so surface-mute has something to mute.
    public var hasActiveNotificationChannel: Bool {
      systemNotificationsEnabled || notificationSound != .never
    }

    /// Custom-folder targets present in state for an agent, ordered by path.
    func customTargets(for agent: SkillAgent) -> [AgentInstallTarget] {
      agentIntegrationStates.keys
        .filter { $0.agent == agent && $0.location != .standard }
        .sorted { ($0.configDirectoryURL?.path ?? "") < ($1.configDirectoryURL?.path ?? "") }
    }

    /// Every install row for an agent: the default first, then custom folders.
    public func installTargets(for agent: SkillAgent) -> [AgentInstallTarget] {
      [.standard(agent)] + customTargets(for: agent)
    }

    /// Rows for the main "Coding Agents" list (see `AgentIntegrationRowState.isMainListRow`).
    /// An agent with any custom folder always belongs here. Unprobed agents count
    /// as still-checking so they render while resolving.
    public var mainListAgentRows: [SkillAgent] {
      SkillAgent.allCasesByDisplayName.filter { agent in
        !customTargets(for: agent).isEmpty || (agentIntegrationStates[agent] ?? .checking).isMainListRow
      }
    }

    /// Agents whose default resolved to "not installed" with no custom folder:
    /// the collapsed install prompt's avatar lineup.
    public var uninstalledAgents: [SkillAgent] {
      SkillAgent.allCasesByDisplayName.filter { agent in
        customTargets(for: agent).isEmpty && (agentIntegrationStates[agent] ?? .checking).isNotInstalled
      }
    }

    /// Rows for the install modal (see `AgentIntegrationRowState.isInstallSheetCandidate`).
    /// An agent with a custom folder lives in the main list, never the modal.
    public var agentInstallSheetAgents: [SkillAgent] {
      SkillAgent.allCasesByDisplayName.filter { agent in
        customTargets(for: agent).isEmpty
          && (agentIntegrationStates[agent] ?? .checking).isInstallSheetCandidate
      }
    }

    /// Per-agent state for consumers that reason per agent (the sidebar upsell),
    /// collapsing every target for the agent: installed anywhere reads as
    /// installed (silences the prompt), an in-flight or undetermined custom probe
    /// keeps it waiting (never a false upsell), otherwise the default state stands.
    public var standardAgentIntegrationStates: [SkillAgent: AgentIntegrationRowState] {
      var result: [SkillAgent: AgentIntegrationRowState] = [:]
      for agent in SkillAgent.allCases {
        let targetStates = agentIntegrationStates.compactMap { $0.key.agent == agent ? $0.value : nil }
        if targetStates.contains(where: { $0 == .ready(.installed) || $0 == .ready(.outdated) }) {
          result[agent] = .ready(.installed)
        } else if let inFlight = targetStates.first(where: \.isInFlight) {
          result[agent] = inFlight
        } else if let undetermined = targetStates.first(where: \.isUndetermined) {
          result[agent] = undetermined
        } else {
          result[agent] = agentIntegrationStates[.standard(agent)]
        }
      }
      return result
    }

    public init(settings: GlobalSettings = .default) {
      @Dependency(\.openActionAvailability) var openActionAvailability
      installedOpenActions = openActionAvailability.installedActions()
      appearanceMode = settings.appearanceMode
      defaultEditorID = settings.defaultEditorID
      updateChannel = settings.updateChannel
      updatesAutomaticallyCheckForUpdates = settings.updatesAutomaticallyCheckForUpdates
      updatesAutomaticallyDownloadUpdates = settings.updatesAutomaticallyDownloadUpdates
      inAppNotificationsEnabled = settings.inAppNotificationsEnabled
      notificationSound = settings.notificationSound
      systemNotificationsEnabled = settings.systemNotificationsEnabled
      muteNotificationsForActiveSurface = settings.muteNotificationsForActiveSurface
      moveNotifiedWorktreeToTop = settings.moveNotifiedWorktreeToTop
      notificationRetentionLimit = settings.notificationRetentionLimit
      analyticsEnabled = settings.analyticsEnabled
      crashReportsEnabled = settings.crashReportsEnabled
      githubIntegrationEnabled = settings.githubIntegrationEnabled
      gitlabIntegrationEnabled = settings.forgeIntegrationEnabled(forID: "gitlab")
      deleteBranchOnDeleteWorktree = settings.deleteBranchOnDeleteWorktree
      mergedWorktreeAction = settings.mergedWorktreeAction
      promptForWorktreeCreation = settings.promptForWorktreeCreation
      fetchOriginBeforeWorktreeCreation = settings.fetchOriginBeforeWorktreeCreation
      copyIgnoredOnWorktreeCreate = settings.copyIgnoredOnWorktreeCreate
      copyUntrackedOnWorktreeCreate = settings.copyUntrackedOnWorktreeCreate
      pullRequestMergeStrategy = settings.pullRequestMergeStrategy
      terminalThemeSyncEnabled = settings.terminalThemeSyncEnabled
      ghosttyUserConfigMode = settings.ghosttyUserConfigMode
      automatedActionPolicy = settings.automatedActionPolicy
      autoDeleteArchivedWorktreesAfterDays = settings.autoDeleteArchivedWorktreesAfterDays
      shortcutOverrides = settings.shortcutOverrides
      globalScripts = settings.globalScripts
      openFileScript = settings.openFileScript
      richAgentNotificationsEnabled = settings.richAgentNotificationsEnabled
      agentPresenceBadgesEnabled = settings.agentPresenceBadgesEnabled
      confirmQuitMode = settings.confirmQuitMode
      confirmCloseSurface = settings.confirmCloseSurface
      confirmCloseTab = settings.confirmCloseTab
      terminateSessionsOnQuit = settings.terminateSessionsOnQuit
      remoteSessionPersistenceEnabled = settings.remoteSessionPersistenceEnabled
      appVisibility = settings.appVisibility
      terminalHibernationEnabled = settings.terminalHibernationEnabled
      chromeTextSize = settings.chromeTextSize
      automaticRepositoryRefreshEnabled = settings.automaticRepositoryRefreshEnabled
      automaticRepositoryRefreshInterval = settings.automaticRepositoryRefreshInterval
      hoverFocusMode = settings.hoverFocusMode
      globalToggleVisibilityHotkey = settings.globalToggleVisibilityHotkey
      defaultWorktreeBaseDirectoryPath =
        SupacodePaths.normalizedWorktreeBaseDirectoryPath(settings.defaultWorktreeBaseDirectoryPath) ?? ""
    }

  }

  public enum Action: BindableAction {
    case task
    case settingsLoaded(GlobalSettings)
    case repositoriesChanged([SettingsRepositorySummary])
    case setSelection(SettingsSection?)
    case setSystemNotificationsEnabled(Bool)
    case setAppVisibility(AppVisibility)
    case setGlobalToggleHotkey(AppShortcutOverride?)
    case setGlobalHotkeyRegistrationFailed(Bool)
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
    case agentIntegrationChecked(AgentInstallTarget, Result<AgentIntegrationState, Error>)
    case agentIntegrationInstallTapped(AgentInstallTarget)
    case agentIntegrationUninstallTapped(AgentInstallTarget)
    case agentIntegrationCompleted(
      AgentInstallTarget,
      Result<AgentIntegrationState, Error>,
      failureIsTransient: Bool,
      expected: AgentIntegrationState
    )
    /// The write succeeded but the follow-up read failed, so it can be neither
    /// confirmed nor called a failure. Carries the verdict from before the write.
    case agentIntegrationUnverified(AgentInstallTarget, lastKnown: AgentIntegrationState?, reason: String)
    case agentInstallSheetOpenTapped
    case setAgentInstallSheetPresented(Bool)
    case agentAddCustomFolderTapped(SkillAgent)
    case agentCustomFolderPicked(SkillAgent, URL)
    case agentConfigDirectoriesResolved(Set<AgentInstallTarget>)
    case agentCustomFolderPersistFailed(AgentInstallTarget, reason: String)
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
  @Dependency(\.directoryPicker) private var directoryPicker
  @Dependency(ArchivedWorktreeDatesClient.self) private var archivedWorktreeDatesClient
  @Dependency(SystemNotificationClient.self) private var systemNotificationClient
  @Dependency(NotificationSoundClient.self) private var notificationSoundClient
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
        // Custom folders aren't filesystem-discoverable; they exist only because
        // `agents.json` records them. Probe them alongside the default targets.
        @Shared(.agentsFile) var agentsFile
        // Skip custom records whose agent can't be relocated: the factory ignores
        // their path, so a shown row would silently operate on the default dir.
        let customTargets = agentsFile.agents.compactMap {
          $0.path != nil && $0.target.agent.supportsCustomConfigFolder ? $0.target : nil
        }
        // Seed custom rows so they render while their probe resolves; default
        // rows already default to `.checking` in the row computeds.
        for target in customTargets where state.agentIntegrationStates[target] == nil {
          state.agentIntegrationStates[target] = .checking
        }
        let targets = SkillAgent.allCases.map(AgentInstallTarget.standard) + customTargets
        return .run { [agentIntegrationClient] send in
          // Resolve which config dirs exist off the main thread, so the view's
          // Finder link reads observable state instead of statting in its body.
          let onDisk = targets.filter {
            FileManager.default.fileExists(atPath: $0.configDirectory().path(percentEncoded: false))
          }
          await send(.agentConfigDirectoriesResolved(Set(onDisk)))
          await withTaskGroup(of: (AgentInstallTarget, Result<AgentIntegrationState, Error>).self) { group in
            for target in targets {
              group.addTask {
                do {
                  return (target, .success(try await agentIntegrationClient.state(target)))
                } catch {
                  return (target, .failure(error))
                }
              }
            }
            for await (target, probe) in group {
              await send(.agentIntegrationChecked(target, probe))
            }
          }
        }
        .cancellable(id: RefreshAgentIntegrationStatesID(), cancelInFlight: true)

      case .settingsLoaded(let settings):
        let normalizedWorktreeBaseDirPath =
          SupacodePaths.normalizedWorktreeBaseDirectoryPath(settings.defaultWorktreeBaseDirectoryPath)
        var normalizedSettings = settings
        normalizedSettings.defaultWorktreeBaseDirectoryPath = normalizedWorktreeBaseDirPath
        if normalizedWorktreeBaseDirPath != settings.defaultWorktreeBaseDirectoryPath {
          // Write only the field being canonicalized so a load never clobbers a
          // concurrent write to the rest of the on-disk settings.
          @Shared(.settingsFile) var settingsFile
          $settingsFile.withLock { $0.global.defaultWorktreeBaseDirectoryPath = normalizedWorktreeBaseDirPath }
        }
        state.appearanceMode = normalizedSettings.appearanceMode
        state.defaultEditorID = normalizedSettings.defaultEditorID
        state.updateChannel = normalizedSettings.updateChannel
        state.updatesAutomaticallyCheckForUpdates = normalizedSettings.updatesAutomaticallyCheckForUpdates
        state.updatesAutomaticallyDownloadUpdates = normalizedSettings.updatesAutomaticallyDownloadUpdates
        state.inAppNotificationsEnabled = normalizedSettings.inAppNotificationsEnabled
        state.notificationSound = normalizedSettings.notificationSound
        state.systemNotificationsEnabled = normalizedSettings.systemNotificationsEnabled
        state.muteNotificationsForActiveSurface = normalizedSettings.muteNotificationsForActiveSurface
        state.moveNotifiedWorktreeToTop = normalizedSettings.moveNotifiedWorktreeToTop
        state.notificationRetentionLimit = normalizedSettings.notificationRetentionLimit
        state.analyticsEnabled = normalizedSettings.analyticsEnabled
        state.crashReportsEnabled = normalizedSettings.crashReportsEnabled
        state.githubIntegrationEnabled = normalizedSettings.githubIntegrationEnabled
        state.gitlabIntegrationEnabled = normalizedSettings.forgeIntegrationEnabled(forID: "gitlab")
        state.deleteBranchOnDeleteWorktree = normalizedSettings.deleteBranchOnDeleteWorktree
        state.mergedWorktreeAction = normalizedSettings.mergedWorktreeAction
        state.promptForWorktreeCreation = normalizedSettings.promptForWorktreeCreation
        state.fetchOriginBeforeWorktreeCreation = normalizedSettings.fetchOriginBeforeWorktreeCreation
        state.copyIgnoredOnWorktreeCreate = normalizedSettings.copyIgnoredOnWorktreeCreate
        state.copyUntrackedOnWorktreeCreate = normalizedSettings.copyUntrackedOnWorktreeCreate
        state.pullRequestMergeStrategy = normalizedSettings.pullRequestMergeStrategy
        state.terminalThemeSyncEnabled = normalizedSettings.terminalThemeSyncEnabled
        state.ghosttyUserConfigMode = normalizedSettings.ghosttyUserConfigMode
        state.automatedActionPolicy = normalizedSettings.automatedActionPolicy
        state.autoDeleteArchivedWorktreesAfterDays = normalizedSettings.autoDeleteArchivedWorktreesAfterDays
        state.shortcutOverrides = normalizedSettings.shortcutOverrides
        state.globalScripts = normalizedSettings.globalScripts
        state.openFileScript = normalizedSettings.openFileScript
        state.richAgentNotificationsEnabled = normalizedSettings.richAgentNotificationsEnabled
        state.agentPresenceBadgesEnabled = normalizedSettings.agentPresenceBadgesEnabled
        state.confirmQuitMode = normalizedSettings.confirmQuitMode
        state.confirmCloseSurface = normalizedSettings.confirmCloseSurface
        state.confirmCloseTab = normalizedSettings.confirmCloseTab
        state.terminateSessionsOnQuit = normalizedSettings.terminateSessionsOnQuit
        state.remoteSessionPersistenceEnabled = normalizedSettings.remoteSessionPersistenceEnabled
        state.appVisibility = normalizedSettings.appVisibility
        state.terminalHibernationEnabled = normalizedSettings.terminalHibernationEnabled
        state.chromeTextSize = normalizedSettings.chromeTextSize
        state.automaticRepositoryRefreshEnabled = normalizedSettings.automaticRepositoryRefreshEnabled
        state.automaticRepositoryRefreshInterval = normalizedSettings.automaticRepositoryRefreshInterval
        state.hoverFocusMode = normalizedSettings.hoverFocusMode
        state.globalToggleVisibilityHotkey = normalizedSettings.globalToggleVisibilityHotkey
        state.defaultWorktreeBaseDirectoryPath = normalizedSettings.defaultWorktreeBaseDirectoryPath ?? ""
        state.syncGlobalDefaults()
        synchronizeRepositorySelection(for: &state)
        return .send(.delegate(.settingsChanged(normalizedSettings)))

      case .binding(\.notificationSound):
        let sound = state.notificationSound
        // Preview the chosen sound, but only on the in-app path: with system
        // notifications on, the banner plays the macOS default instead. `.never`
        // has nothing to audition.
        let shouldPreview = !state.systemNotificationsEnabled && sound != .never
        state.syncGlobalDefaults()
        return .merge(
          persist(state),
          shouldPreview ? .run { _ in await notificationSoundClient.play(sound) } : .none
        )

      case .binding:
        state.syncGlobalDefaults()
        return persist(state)

      case .setSystemNotificationsEnabled(let isEnabled):
        state.systemNotificationsEnabled = isEnabled
        state.syncGlobalDefaults()
        return persist(state)

      case .setAppVisibility(let visibility):
        // MenuBarExtra echoes the current value on every scene evaluation;
        // persisting each echo would loop scene -> persist -> scene.
        guard state.appVisibility != visibility else { return .none }
        state.appVisibility = visibility
        state.syncGlobalDefaults()
        return persist(state)

      case .setGlobalToggleHotkey(let override):
        // Presence encodes "bound", so collapse a disabled chord to nil; the row
        // and the monitor both read nil-or-enabled and would otherwise disagree.
        let normalized = override?.isEnabled == true ? override : nil
        guard state.globalToggleVisibilityHotkey != normalized else { return .none }
        state.globalToggleVisibilityHotkey = normalized
        // A fresh chord clears the stale registration-failure warning; the
        // pending registration decides whether it comes back.
        state.globalHotkeyRegistrationFailed = false
        state.syncGlobalDefaults()
        return persist(state)

      case .setGlobalHotkeyRegistrationFailed(let failed):
        state.globalHotkeyRegistrationFailed = failed
        return .none

      case .setAutomatedActionPolicy(let policy):
        state.automatedActionPolicy = policy
        state.syncGlobalDefaults()
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

      case .agentIntegrationChecked(let target, let probe):
        // A custom target removed from agents.json (uninstalled) must not be
        // resurrected by an in-flight probe that predates the removal.
        if target.location != .standard {
          @Shared(.agentsFile) var agentsFile
          guard agentsFile.agents.contains(where: { $0.target == target }) else { return .none }
        }
        // Don't clobber in-flight or failed states. `.installing` /
        // `.uninstalling` settle via `.agentIntegrationCompleted`;
        // overwriting them races the shared `AgentIntegrationCancelID`
        // (the re-install below would otherwise cancel a manual uninstall).
        // `.failed`/`.failedTransient` must survive so the error stays visible
        // and the re-install can't loop on a persistent failure.
        let previous = state.agentIntegrationStates[target]
        switch previous {
        case .installing, .uninstalling, .failed, .failedTransient: return .none
        case nil, .checking, .ready, .undetermined: break
        }
        let resolved: AgentIntegrationState
        switch probe {
        case .success(let value):
          resolved = value
        case .failure(let error):
          // Never `.failed`: that state is sticky for the session, and a probe
          // fault clears as soon as the file becomes readable, which only a
          // re-probe can observe. No auto-install against a file we can't read.
          settingsFeatureLogger.warning("\(target.agent.rawValue) integration state unreadable: \(error)")
          state.agentIntegrationStates[target] = .undetermined(
            lastKnown: previous?.lastKnownState,
            reason: Self.probeFailureMessage(error)
          )
          dismissInstallSheetIfSettled(&state)
          return .none
        }
        state.agentIntegrationStates[target] = .ready(resolved)
        // Reconcile the record with disk: an install found on disk earns a record
        // so `agents.json` stays the source of truth. Absence never removes a
        // record, so a recorded target reading `.notInstalled` shows as a wrong
        // install, not a silent forget.
        if resolved != .notInstalled { Self.addRecordIfMissing(for: target) }
        // A refresh (not just a completed install) can be what finally empties
        // the modal, e.g. an agent installed externally between activations.
        dismissInstallSheetIfSettled(&state)
        // Re-install an outdated integration, but only once per session: our
        // hooks are matched by signal, so `.outdated` means our own components
        // drifted. Re-arming on every activation would be a silent, unbounded
        // hook rewrite.
        guard resolved == .outdated, !state.autoInstalledTargets.contains(target) else { return .none }
        state.autoInstalledTargets.insert(target)
        return .send(.agentIntegrationInstallTapped(target))

      case .agentIntegrationInstallTapped(let target):
        // A fresh install of a not-yet-present agent surfaces failures
        // transiently in the modal; retrying a persistent error or updating an
        // already-present integration keeps them as a main-list row. Custom
        // folders never live in the modal, so their errors are always persistent.
        let failureIsTransient: Bool
        if target.location != .standard {
          failureIsTransient = false
        } else {
          switch state.agentIntegrationStates[target] {
          case .ready(.installed), .ready(.outdated), .failed, .undetermined: failureIsTransient = false
          case nil, .checking, .installing, .uninstalling, .ready(.notInstalled), .failedTransient:
            failureIsTransient = true
          }
        }
        // Captured before the write: an unverifiable read afterwards must not
        // erase what the auto-update guard already knew.
        let lastKnown = state.agentIntegrationStates[target]?.lastKnownState
        state.agentIntegrationStates[target] = .installing
        return .run { [agentIntegrationClient] send in
          do {
            try await agentIntegrationClient.install(target)
          } catch {
            await send(
              .agentIntegrationCompleted(
                target, .failure(error), failureIsTransient: failureIsTransient, expected: .installed))
            return
          }
          await send(
            Self.verificationAction(
              target: target,
              expected: .installed,
              lastKnown: lastKnown,
              failureIsTransient: failureIsTransient,
              client: agentIntegrationClient
            ))
        }
        // Cancel an in-flight install for the same TARGET if Settings is reopened
        // mid-flight, otherwise two effects race the same config dir's read-modify-
        // write. Per-target (not per-agent) so a custom install never cancels the default's.
        .cancellable(id: AgentIntegrationCancelID(target: target), cancelInFlight: true)

      case .agentIntegrationUninstallTapped(let target):
        let lastKnown = state.agentIntegrationStates[target]?.lastKnownState
        state.agentIntegrationStates[target] = .uninstalling
        return .run { [agentIntegrationClient] send in
          do {
            try await agentIntegrationClient.uninstall(target)
          } catch {
            // An uninstall failure is a persistent main-list error, not a modal one.
            await send(
              .agentIntegrationCompleted(
                target, .failure(error), failureIsTransient: false, expected: .notInstalled))
            return
          }
          await send(
            Self.verificationAction(
              target: target,
              expected: .notInstalled,
              lastKnown: lastKnown,
              failureIsTransient: false,
              client: agentIntegrationClient
            ))
        }
        .cancellable(id: AgentIntegrationCancelID(target: target), cancelInFlight: true)

      case .agentIntegrationCompleted(let target, .success(let integrationState), _, let expected):
        // The operation reported success, so trust the disk, not the report: a
        // write that did not land must not render as a healthy row.
        guard integrationState == expected else {
          state.agentIntegrationStates[target] = .failed(
            Self.unlandedWriteMessage(agent: target.agent, expected: expected, actual: integrationState))
          dismissInstallSheetIfSettled(&state)
          return .none
        }
        state.agentIntegrationStates[target] = .ready(integrationState)
        // Keep `agents.json` in step with the write that just landed: an
        // install earns a record, an uninstall drops it.
        if expected == .notInstalled {
          Self.removeRecord(for: target)
          // An uninstalled custom folder has no row to show, so drop it rather
          // than linger as an empty line. The default's row stays and reverts to the prompt.
          if target.location != .standard { state.agentIntegrationStates[target] = nil }
        } else {
          Self.addRecordIfMissing(for: target)
        }
        dismissInstallSheetIfSettled(&state)
        return .none

      case .agentIntegrationUnverified(let target, let lastKnown, let reason):
        // Only the confirming read failed, so claiming either outcome would be
        // a guess.
        settingsFeatureLogger.warning("\(target.agent.rawValue) integration could not be verified: \(reason)")
        state.agentIntegrationStates[target] = .undetermined(lastKnown: lastKnown, reason: reason)
        dismissInstallSheetIfSettled(&state)
        return .none

      case .agentIntegrationCompleted(let target, .failure(let error), let failureIsTransient, _):
        if error is AgentIntegrationError {
          settingsFeatureLogger.warning(
            "\(target.agent.rawValue) integration install skipped: \(error.localizedDescription)")
        } else {
          settingsFeatureLogger.error("\(target.agent.rawValue) integration operation failed: \(error)")
        }
        // A transient error has no home once its modal is gone: re-resolve the
        // real state instead of stranding an invisible row.
        if failureIsTransient, !state.agentInstallSheetPresented {
          state.agentIntegrationStates[target] = .checking
          return .send(.refreshAgentIntegrationStates)
        }
        let message = error.localizedDescription
        state.agentIntegrationStates[target] = failureIsTransient ? .failedTransient(message) : .failed(message)
        // A persistent failure can be the last modal candidate settling, which
        // would otherwise leave the sheet presented over an empty form.
        dismissInstallSheetIfSettled(&state)
        return .none

      case .agentInstallSheetOpenTapped:
        // Never present the modal empty. The prompt row that sends this is
        // itself hidden when nothing is installable, so this is belt-and-braces.
        guard !state.uninstalledAgents.isEmpty else { return .none }
        state.agentInstallSheetPresented = true
        return .none

      case .setAgentInstallSheetPresented(let presented):
        state.agentInstallSheetPresented = presented
        guard !presented else { return .none }
        // Dismissing the modal clears its transient install errors: drop those
        // rows and re-probe so they revert to real on-disk state. Persistent
        // `.failed` rows (uninstall / update errors) are left untouched.
        var clearedFailure = false
        for agent in SkillAgent.allCases {
          guard case .failedTransient = state.agentIntegrationStates[agent] else { continue }
          state.agentIntegrationStates[agent] = .checking
          clearedFailure = true
        }
        return clearedFailure ? .send(.refreshAgentIntegrationStates) : .none

      case .agentAddCustomFolderTapped(let agent):
        // Only agents whose whole integration relocates can take a custom folder.
        guard agent.supportsCustomConfigFolder else { return .none }
        return .run { [directoryPicker] send in
          let message = "Choose a folder to install the \(agent.displayName) integration into."
          guard let url = await directoryPicker.pickDirectory(message) else { return }
          await send(.agentCustomFolderPicked(agent, url))
        }

      case .agentCustomFolderPicked(let agent, let url):
        let picked = url.standardizedFileURL
        // Reject a folder already backing another integration: two targets on one
        // config dir would race the same files, breaking per-target cancellation.
        if let owner = Self.integrationOwner(ofFolder: picked, among: state.agentIntegrationStates.keys) {
          state.alert = AlertState {
            TextState("Folder Already in Use")
          } actions: {
            ButtonState(role: .cancel, action: .dismiss) { TextState("OK") }
          } message: {
            let display = (picked.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
            return TextState("\(display) already holds the \(owner.displayName) integration.")
          }
          return .none
        }
        let target = AgentInstallTarget(
          agent: agent, location: .custom(configDirectoryPath: picked.path(percentEncoded: false)))
        // The picked folder exists (the panel returns a real dir), so its path links to Finder now.
        state.configDirectoriesOnDisk.insert(target)
        // Persist the record before installing, and only install once it's durably
        // saved: a record that never reaches disk would orphan the install next
        // launch, since custom folders are their own sole on-disk trace.
        return .run { send in
          @Shared(.agentsFile) var agentsFile
          let didAppend = $agentsFile.withLock { file -> Bool in
            guard !file.agents.contains(where: { $0.target == target }) else { return false }
            file.agents.append(target.installRecord)
            return true
          }
          do {
            // `save()` flushes the pending write the `withLock` scheduled, and
            // surfaces its error: this is the same durable write, not a duplicate.
            try await $agentsFile.save()
          } catch {
            // Roll back only what this effect appended, so a pre-existing record survives.
            if didAppend { $agentsFile.withLock { $0.agents.removeAll { $0.target == target } } }
            await send(.agentCustomFolderPersistFailed(target, reason: error.localizedDescription))
            return
          }
          await send(.agentIntegrationInstallTapped(target))
        }

      case .agentConfigDirectoriesResolved(let dirs):
        state.configDirectoriesOnDisk = dirs
        return .none

      case .agentCustomFolderPersistFailed(let target, let reason):
        // The install never started, so drop the optimistic Finder-link entry.
        state.configDirectoriesOnDisk.remove(target)
        state.alert = AlertState {
          TextState("Couldn't Save the Folder")
        } actions: {
          ButtonState(role: .cancel, action: .dismiss) { TextState("OK") }
        } message: {
          TextState(
            "Supacode couldn't record the folder in agents.json, so the integration "
              + "wasn't installed. \(reason)")
        }
        return .none

      case .updateShortcut(let id, let override):
        // A non-customizable shortcut ignores overrides; refuse to persist one.
        guard AppShortcuts.all.first(where: { $0.id == id })?.isCustomizable != false else { return .none }
        if let override {
          state.shortcutOverrides[id] = override
        } else {
          state.shortcutOverrides.removeValue(forKey: id)
        }
        return persist(state)

      case .toggleShortcutEnabled(let id, let enabled):
        // A non-customizable shortcut is always enabled; refuse to persist a toggle.
        guard AppShortcuts.all.first(where: { $0.id == id })?.isCustomizable != false else { return .none }
        if enabled {
          // A real binding just flips its enabled flag. A sentinel (or no override)
          // carries no binding, so restore the default: a disabled-by-default
          // shortcut needs its default key bound, an enabled-by-default one drops
          // the sentinel.
          if var existing = state.shortcutOverrides[id], existing.keyCode != 0 || !existing.modifiers.isEmpty {
            existing.isEnabled = true
            state.shortcutOverrides[id] = existing
          } else if let override = AppShortcuts.defaultEnabledOverride(for: id) {
            state.shortcutOverrides[id] = override
          } else {
            state.shortcutOverrides.removeValue(forKey: id)
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
    // Merge only the fields this feature owns onto the live on-disk settings, so
    // an unowned field survives verbatim instead of being reset by a full rebuild.
    @Shared(.settingsFile) var settingsFile
    let settings = $settingsFile.withLock { file -> GlobalSettings in
      state.applyOwnedFields(to: &file.global)
      return file.global
    }
    if settings.analyticsEnabled {
      analyticsClient.capture("settings_changed", nil)
    }
    return .send(.delegate(.settingsChanged(settings)))
  }

  /// Re-read the state after a successful write. An unreadable follow-up is
  /// reported as unverified rather than as a failure we did not observe.
  private static func verificationAction(
    target: AgentInstallTarget,
    expected: AgentIntegrationState,
    lastKnown: AgentIntegrationState?,
    failureIsTransient: Bool,
    client: AgentIntegrationClient
  ) async -> Action {
    do {
      let next = try await client.state(target)
      return .agentIntegrationCompleted(
        target, .success(next), failureIsTransient: failureIsTransient, expected: expected)
    } catch {
      let detail = Self.sentence(
        "\(Self.writeVerb(for: expected)) the \(target.agent.displayName) integration, but couldn't "
          + "read it back to confirm. \(error.localizedDescription)")
      return .agentIntegrationUnverified(target, lastKnown: lastKnown, reason: Self.withRetryNote(detail))
    }
  }

  /// Says what the fault means for the row, since the error alone reads as a
  /// bare filesystem complaint.
  private static func probeFailureMessage(_ error: Error) -> String {
    let detail =
      error is AgentFileUnreadableError
      ? error.localizedDescription
      : "Couldn't determine whether the integration is installed. \(error.localizedDescription)"
    return withRetryNote(sentence(detail))
  }

  /// Every undetermined row re-probes on the next activation, so every message
  /// that produces one says so.
  private static func withRetryNote(_ sentence: String) -> String {
    "\(sentence) Supacode retries when you switch back to it."
  }

  /// Foundation error descriptions already end in a period; ours don't always.
  private static func sentence(_ text: String) -> String {
    text.hasSuffix(".") ? text : "\(text)."
  }

  /// Past-tense verb for the write we just attempted.
  private static func writeVerb(for expected: AgentIntegrationState) -> String {
    expected == .notInstalled ? "Removed" : "Installed"
  }

  /// States what the read-back found without asserting a cause: the write may
  /// have landed and a different component be the laggard.
  private static func unlandedWriteMessage(
    agent: SkillAgent,
    expected: AgentIntegrationState,
    actual: AgentIntegrationState
  ) -> String {
    "\(Self.writeVerb(for: expected)) the \(agent.displayName) integration, but it still reads as "
      + "\(Self.stateDescription(actual)) on disk."
  }

  private static func stateDescription(_ state: AgentIntegrationState) -> String {
    switch state {
    case .installed: "installed"
    case .notInstalled: "not installed"
    case .outdated: "out of date"
    }
  }

  /// Close the install modal once nothing installable remains, so it never
  /// lingers empty after the last install settles or a refresh resolves it.
  private func dismissInstallSheetIfSettled(_ state: inout State) {
    guard state.agentInstallSheetPresented, state.agentInstallSheetAgents.isEmpty else { return }
    state.agentInstallSheetPresented = false
  }

  /// The agent whose config directory resolves to `folder`, if any. Used to
  /// refuse pointing two integrations at one directory.
  private static func integrationOwner(
    ofFolder folder: URL,
    among keys: some Collection<AgentInstallTarget>
  ) -> SkillAgent? {
    let wanted = canonicalPath(folder)
    let home = FileManager.default.homeDirectoryForCurrentUser
    for agent in SkillAgent.allCases {
      let dir = home.appending(path: agent.configDirectoryName, directoryHint: .isDirectory)
      if canonicalPath(dir) == wanted { return agent }
    }
    for key in keys where key.location != .standard {
      guard let url = key.configDirectoryURL else { continue }
      if canonicalPath(url) == wanted { return key.agent }
    }
    return nil
  }

  /// Symlink-resolved, standardized path for comparing two directory URLs.
  private static func canonicalPath(_ url: URL) -> String {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    // A non-existent directory resolves with an inconsistent trailing slash
    // depending on how the URL was built, so two URLs to the same dir would
    // compare unequal; drop it so the comparison is stable.
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  /// Records the target in `agents.json` unless it is already there.
  private static func addRecordIfMissing(for target: AgentInstallTarget) {
    @Shared(.agentsFile) var agentsFile
    // Check and append in one critical section so two concurrent writers can't
    // both pass the guard and append a duplicate record.
    $agentsFile.withLock { file in
      guard !file.agents.contains(where: { $0.target == target }) else { return }
      file.agents.append(target.installRecord)
    }
  }

  /// Drops every `agents.json` record matching the target (an uninstall).
  private static func removeRecord(for target: AgentInstallTarget) {
    @Shared(.agentsFile) var agentsFile
    $agentsFile.withLock { $0.agents.removeAll { $0.target == target } }
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
    state.syncGlobalDefaults()
  }
}

/// Cancellation key for in-flight integration install/uninstall effects so
/// the next tap (or a fresh Settings open) supersedes the prior one. Keyed by
/// target so two folders of one agent never cancel each other.
private nonisolated struct AgentIntegrationCancelID: Hashable, Sendable {
  let target: AgentInstallTarget
}

/// Cancellation key for the agent-state refresh effect so stacked scene
/// activations supersede the prior one. See `.refreshAgentIntegrationStates`.
private nonisolated struct RefreshAgentIntegrationStatesID: Hashable, Sendable {}

extension SettingsFeature.State {
  mutating func syncGlobalDefaults() {
    guard var repositorySettings else { return }
    repositorySettings.globalDefaultWorktreeBaseDirectoryPath =
      SupacodePaths.normalizedWorktreeBaseDirectoryPath(defaultWorktreeBaseDirectoryPath)
    repositorySettings.globalCopyIgnoredOnWorktreeCreate = copyIgnoredOnWorktreeCreate
    repositorySettings.globalCopyUntrackedOnWorktreeCreate = copyUntrackedOnWorktreeCreate
    repositorySettings.globalPullRequestMergeStrategy = pullRequestMergeStrategy
    repositorySettings.globalMergedWorktreeAction = mergedWorktreeAction
    self.repositorySettings = repositorySettings
  }

  /// Writes the fields this feature owns onto `settings`, leaving the rest
  /// untouched. The single source of truth for what Settings persists: a field
  /// absent here rides through verbatim instead of resetting to its default.
  func applyOwnedFields(to settings: inout GlobalSettings) {
    settings.appearanceMode = appearanceMode
    settings.defaultEditorID = defaultEditorID
    settings.updateChannel = updateChannel
    settings.updatesAutomaticallyCheckForUpdates = updatesAutomaticallyCheckForUpdates
    settings.updatesAutomaticallyDownloadUpdates = updatesAutomaticallyDownloadUpdates
    settings.inAppNotificationsEnabled = inAppNotificationsEnabled
    settings.notificationSound = notificationSound
    settings.systemNotificationsEnabled = systemNotificationsEnabled
    settings.muteNotificationsForActiveSurface = muteNotificationsForActiveSurface
    settings.moveNotifiedWorktreeToTop = moveNotifiedWorktreeToTop
    settings.notificationRetentionLimit = notificationRetentionLimit
    settings.analyticsEnabled = analyticsEnabled
    settings.crashReportsEnabled = crashReportsEnabled
    settings.githubIntegrationEnabled = githubIntegrationEnabled
    settings.forgeEnabledByID = gitlabIntegrationEnabled ? [:] : ["gitlab": false]
    settings.deleteBranchOnDeleteWorktree = deleteBranchOnDeleteWorktree
    settings.mergedWorktreeAction = mergedWorktreeAction
    settings.promptForWorktreeCreation = promptForWorktreeCreation
    settings.fetchOriginBeforeWorktreeCreation = fetchOriginBeforeWorktreeCreation
    settings.copyIgnoredOnWorktreeCreate = copyIgnoredOnWorktreeCreate
    settings.copyUntrackedOnWorktreeCreate = copyUntrackedOnWorktreeCreate
    settings.pullRequestMergeStrategy = pullRequestMergeStrategy
    settings.terminalThemeSyncEnabled = terminalThemeSyncEnabled
    settings.ghosttyUserConfigMode = ghosttyUserConfigMode
    settings.automatedActionPolicy = automatedActionPolicy
    settings.defaultWorktreeBaseDirectoryPath =
      SupacodePaths.normalizedWorktreeBaseDirectoryPath(defaultWorktreeBaseDirectoryPath)
    settings.autoDeleteArchivedWorktreesAfterDays = autoDeleteArchivedWorktreesAfterDays
    settings.shortcutOverrides = shortcutOverrides
    settings.globalScripts = globalScripts
    settings.openFileScript = openFileScript
    settings.richAgentNotificationsEnabled = richAgentNotificationsEnabled
    settings.agentPresenceBadgesEnabled = agentPresenceBadgesEnabled
    settings.confirmQuitMode = confirmQuitMode
    settings.confirmCloseSurface = confirmCloseSurface
    settings.confirmCloseTab = confirmCloseTab
    settings.terminateSessionsOnQuit = terminateSessionsOnQuit
    settings.remoteSessionPersistenceEnabled = remoteSessionPersistenceEnabled
    settings.appVisibility = appVisibility
    settings.terminalHibernationEnabled = terminalHibernationEnabled
    settings.chromeTextSize = chromeTextSize
    settings.automaticRepositoryRefreshEnabled = automaticRepositoryRefreshEnabled
    settings.automaticRepositoryRefreshInterval = automaticRepositoryRefreshInterval
    settings.hoverFocusMode = hoverFocusMode
    settings.globalToggleVisibilityHotkey = globalToggleVisibilityHotkey
  }
}
