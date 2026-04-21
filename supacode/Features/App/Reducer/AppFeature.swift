import AppKit
import ComposableArchitecture
import Foundation
import PostHog
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

private nonisolated let appLogger = SupaLogger("App")
private nonisolated let deeplinkLogger = SupaLogger("Deeplink")
private nonisolated let jumpLogger = SupaLogger("JumpToLatestUnread")
private nonisolated let notificationsLogger = SupaLogger("Notifications")

private enum CancelID {
  static let periodicRefresh = "app.periodicRefresh"
}

@Reducer
struct AppFeature {
  @ObservableState
  struct State: Equatable {
    var repositories: RepositoriesFeature.State
    var settings: SettingsFeature.State
    var updates = UpdatesFeature.State()
    var commandPalette = CommandPaletteFeature.State()
    var openActionSelection: OpenWorktreeAction = .finder
    var scripts: [ScriptDefinition] = []
    var notificationIndicatorCount: Int = 0
    var lastKnownSystemNotificationsEnabled: Bool
    var pendingDeeplinks: [Deeplink] = []
    var isDeeplinkReferenceRequested = false
    @Presents var alert: AlertState<Alert>?
    @Presents var deeplinkInputConfirmation: DeeplinkInputConfirmationFeature.State?

    init(
      repositories: RepositoriesFeature.State = .init(),
      settings: SettingsFeature.State = .init()
    ) {
      self.repositories = repositories
      self.settings = settings
      lastKnownSystemNotificationsEnabled = settings.systemNotificationsEnabled
    }

    /// The script that the primary toolbar button should run.
    var primaryScript: ScriptDefinition? {
      scripts.primaryScript
    }

    /// Running script IDs for the currently selected worktree.
    var runningScriptIDs: Set<UUID> {
      guard
        let worktreeID = repositories.selectedWorktreeID,
        let tints = repositories.runningScriptsByWorktreeID[worktreeID]
      else { return [] }
      return Set(tints.keys)
    }

    /// Whether any `.run`-kind script is currently running in the selected worktree.
    var hasRunningRunScript: Bool {
      scripts.hasRunningRunScript(in: runningScriptIDs)
    }
  }

  enum Action {
    case appLaunched
    case scenePhaseChanged(ScenePhase)
    case repositories(RepositoriesFeature.Action)
    case settings(SettingsFeature.Action)
    case updates(UpdatesFeature.Action)
    case commandPalette(CommandPaletteFeature.Action)
    case openActionSelectionChanged(OpenWorktreeAction)
    case worktreeSettingsLoaded(RepositorySettings, worktreeID: Worktree.ID)
    case openSelectedWorktree
    case revealInFinder
    case openWorktree(OpenWorktreeAction)
    case openWorktreeFailed(OpenActionError)
    case requestQuit
    case newTerminal
    case jumpToLatestUnread
    case runScript
    case runNamedScript(ScriptDefinition)
    case stopScript(ScriptDefinition)
    case stopRunScripts
    case closeTab
    case closeSurface
    case startSearch
    case searchSelection
    case navigateSearchNext
    case navigateSearchPrevious
    case endSearch
    case systemNotificationsPermissionFailed(errorMessage: String?)
    case deeplinkReceived(URL, source: ActionSource = .urlScheme, responseFD: Int32? = nil)
    case deeplink(Deeplink, source: ActionSource = .urlScheme, responseFD: Int32? = nil)
    case deeplinkReferenceOpened
    case alert(PresentationAction<Alert>)
    case deeplinkInputConfirmation(PresentationAction<DeeplinkInputConfirmationFeature.Action>)
    case terminalEvent(TerminalClient.Event)
  }

  enum Alert: Equatable {
    case dismiss
    case confirmQuit
  }

  @Dependency(AnalyticsClient.self) private var analyticsClient
  @Dependency(DeeplinkClient.self) private var deeplinkClient
  @Dependency(RepositoryPersistenceClient.self) private var repositoryPersistence
  @Dependency(WorkspaceClient.self) private var workspaceClient
  @Dependency(NotificationSoundClient.self) private var notificationSoundClient
  @Dependency(SystemNotificationClient.self) private var systemNotificationClient
  @Dependency(TerminalClient.self) private var terminalClient
  @Dependency(WorktreeInfoWatcherClient.self) private var worktreeInfoWatcher

  var body: some Reducer<State, Action> {
    let core = Reduce<State, Action> { state, action in
      switch action {
      case .appLaunched:
        return .merge(
          .send(.repositories(.task)),
          .send(.settings(.task)),
          .run { _ in
            await MainActor.run {
              NSApplication.shared.dockTile.badgeLabel = nil
            }
          },
          .run { send in
            for await event in await terminalClient.events() {
              await send(.terminalEvent(event))
            }
          },
          .run { send in
            for await event in await worktreeInfoWatcher.events() {
              await send(.repositories(.worktreeInfoEvent(event)))
            }
          }
        )

      case .scenePhaseChanged(let phase):
        switch phase {
        case .active:
          analyticsClient.capture("app_activated", nil)
          return .merge(
            .send(.repositories(.refreshWorktrees)),
            .run { send in
              while !Task.isCancelled {
                try? await ContinuousClock().sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await send(.repositories(.refreshWorktrees))
              }
            }
            .cancellable(id: CancelID.periodicRefresh, cancelInFlight: true)
          )
        case .inactive, .background:
          return .cancel(id: CancelID.periodicRefresh)
        @unknown default:
          return .cancel(id: CancelID.periodicRefresh)
        }

      case .repositories(.delegate(.selectedWorktreeChanged(let worktree))):
        let lastFocusedWorktreeID = worktree?.id
        guard let worktree else {
          state.openActionSelection = .finder
          state.scripts = []
          // Selecting the archived list must NOT overwrite the last
          // focused live worktree — preserve `focusedWorktreeID` so
          // returning from archives restores the prior row.
          if !state.repositories.isShowingArchivedWorktrees {
            state.repositories.$sidebar.withLock { sidebar in
              sidebar.focusedWorktreeID = lastFocusedWorktreeID
            }
          }
          return .merge(
            .run { _ in
              await terminalClient.send(.setSelectedWorktreeID(nil))
            },
            .run { _ in
              await worktreeInfoWatcher.send(.setSelectedWorktreeID(nil))
            }
          )
        }
        let rootURL = worktree.repositoryRootURL
        let worktreeID = worktree.id
        state.repositories.$sidebar.withLock { sidebar in
          sidebar.focusedWorktreeID = lastFocusedWorktreeID
        }
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        let settings = repositorySettings
        return .merge(
          .run { _ in
            await terminalClient.send(.setSelectedWorktreeID(worktree.id))
          },
          .run { _ in
            await worktreeInfoWatcher.send(.setSelectedWorktreeID(worktree.id))
          },
          .send(.worktreeSettingsLoaded(settings, worktreeID: worktreeID))
        )

      case .repositories(.delegate(.worktreeCreated(let worktree))):
        let shouldRunSetupScript =
          state.repositories.pendingSetupScriptWorktreeIDs.contains(worktree.id)
        return .run { _ in
          await terminalClient.send(
            .ensureInitialTab(
              worktree,
              runSetupScriptIfNew: shouldRunSetupScript,
              focusing: false
            )
          )
        }

      case .repositories(.delegate(.repositoriesChanged(let repositories))):
        let archivedIDs = state.repositories.archivedWorktreeIDSet
        let deleteScriptIDs = state.repositories.deleteScriptWorktreeIDs
        let ids = Set(
          repositories.flatMap { $0.worktrees.map(\.id) }
            .filter { !archivedIDs.contains($0) || deleteScriptIDs.contains($0) }
        )
        state.repositories.runningScriptsByWorktreeID = state.repositories.runningScriptsByWorktreeID
          .filter { ids.contains($0.key) }
        let recencyIDs = CommandPaletteFeature.recencyRetentionIDs(
          from: repositories,
          scripts: state.scripts
        )
        let worktrees = state.repositories.worktreesForInfoWatcher()
        var effects: [Effect<Action>] = [
          .send(
            .settings(
              .repositoriesChanged(
                repositories.map {
                  SettingsRepositorySummary(
                    id: $0.id,
                    name: $0.name,
                    isGitRepository: $0.isGitRepository
                  )
                }
              )
            )
          ),
          .send(.commandPalette(.pruneRecency(recencyIDs))),
          .run { _ in
            await terminalClient.send(.prune(ids))
          },
          .run { _ in
            await worktreeInfoWatcher.send(.setWorktrees(worktrees))
          },
        ]
        if !state.pendingDeeplinks.isEmpty {
          let pending = state.pendingDeeplinks
          state.pendingDeeplinks.removeAll()
          for deeplink in pending {
            effects.append(.send(.deeplink(deeplink)))
          }
        }
        return .merge(effects)

      case .repositories(.delegate(.openWorktreeInApp(let worktreeID, let action))):
        guard let worktree = state.repositories.worktree(for: worktreeID) else {
          appLogger.warning("openWorktreeInApp: worktree \(worktreeID) not found, ignoring.")
          return .none
        }
        return openWorktreeEffect(worktree: worktree, action: action, source: .contextMenu, state: state)

      case .repositories(.delegate(.openRepositorySettings(let repositoryID))):
        guard let repository = state.repositories.repositories[id: repositoryID] else {
          return .none
        }
        // Folders don't expose the general `.repository` page (no
        // branches, worktree config, etc.) — route them straight to
        // the scripts page which is the only settings surface that
        // applies to them.
        let section: SettingsSection =
          repository.isGitRepository ? .repository(repositoryID) : .repositoryScripts(repositoryID)
        return .send(.settings(.setSelection(section)))

      case .repositories(.delegate(.runBlockingScript(let worktree, _, let kind, let script))):
        return .run { _ in
          await terminalClient.send(.runBlockingScript(worktree, kind: kind, script: script))
        }

      case .repositories(.delegate(.selectTerminalTab(let worktreeID, let tabId))):
        guard let worktree = state.repositories.worktree(for: worktreeID) else { return .none }
        return .run { _ in
          await terminalClient.send(.selectTab(worktree, tabID: tabId))
        }

      case .settings(.delegate(.settingsChanged(let settings))):
        let shouldCheckSystemNotificationPermission =
          settings.systemNotificationsEnabled && !state.lastKnownSystemNotificationsEnabled
        state.lastKnownSystemNotificationsEnabled = settings.systemNotificationsEnabled
        if let selectedWorktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) {
          let rootURL = selectedWorktree.repositoryRootURL
          @Shared(.repositorySettings(rootURL)) var repositorySettings
          state.openActionSelection = OpenWorktreeAction.fromSettingsID(
            repositorySettings.openActionID,
            defaultEditorID: settings.defaultEditorID
          )
        }
        return .merge(
          .send(.repositories(.setGithubIntegrationEnabled(settings.githubIntegrationEnabled))),
          .send(
            .repositories(
              .setMergedWorktreeAction(
                settings.mergedWorktreeAction
              )
            )
          ),
          .send(
            .repositories(
              .setMoveNotifiedWorktreeToTop(
                settings.moveNotifiedWorktreeToTop
              )
            )
          ),
          .send(
            .repositories(
              .setAutoDeleteArchivedWorktreesAfterDays(
                settings.autoDeleteArchivedWorktreesAfterDays
              )
            )
          ),
          .send(
            .updates(
              .applySettings(
                updateChannel: settings.updateChannel,
                automaticallyChecks: settings.updatesAutomaticallyCheckForUpdates,
                automaticallyDownloads: settings.updatesAutomaticallyDownloadUpdates
              )
            )
          ),
          .run { _ in
            await terminalClient.send(.setNotificationsEnabled(settings.inAppNotificationsEnabled))
          },
          .run { _ in
            await terminalClient.send(.refreshTabBarVisibility)
          },
          .run { _ in
            await worktreeInfoWatcher.send(
              .setPullRequestTrackingEnabled(settings.githubIntegrationEnabled)
            )
          },
          .run { send in
            guard shouldCheckSystemNotificationPermission else { return }
            let status = await systemNotificationClient.authorizationStatus()
            switch status {
            case .authorized:
              return
            case .notDetermined:
              let result = await systemNotificationClient.requestAuthorization()
              if !result.granted {
                await send(
                  .systemNotificationsPermissionFailed(errorMessage: result.errorMessage)
                )
              }
            case .denied:
              await send(.systemNotificationsPermissionFailed(errorMessage: "Authorization status is denied."))
            }
          }
        )

      case .openActionSelectionChanged(let action):
        state.openActionSelection = action
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          appLogger.warning("openActionSelectionChanged: selected worktree not found, skipping persistence.")
          return .none
        }
        let rootURL = worktree.repositoryRootURL
        let actionID = action.settingsID
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        $repositorySettings.withLock { $0.openActionID = actionID }
        return .none

      case .openSelectedWorktree:
        return .send(.openWorktree(OpenWorktreeAction.availableSelection(state.openActionSelection)))

      case .revealInFinder:
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          appLogger.warning("revealInFinder: selected worktree not found, ignoring.")
          return .none
        }
        return openWorktreeEffect(worktree: worktree, action: .finder, source: .revealInFinder, state: state)

      case .openWorktree(let action):
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          appLogger.warning("openWorktree: selected worktree not found, ignoring.")
          return .none
        }
        return openWorktreeEffect(worktree: worktree, action: action, source: .toolbar, state: state)

      case .openWorktreeFailed(let error):
        state.alert = AlertState {
          TextState(error.title)
        } actions: {
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("OK")
          }
        } message: {
          TextState(error.message)
        }
        return .none

      case .requestQuit:
        let pendingFDEffect = drainPendingResponseFD(state: &state, error: "Supacode is quitting.")
        #if !DEBUG
          guard state.settings.confirmBeforeQuit else {
            analyticsClient.capture("app_quit", nil)
            return .concatenate(
              pendingFDEffect,
              .run { @MainActor _ in
                NSApplication.shared.terminate(nil)
              })
          }
          state.alert = AlertState {
            TextState("Quit Supacode?")
          } actions: {
            ButtonState(action: .confirmQuit) {
              TextState("Quit")
            }
            ButtonState(role: .cancel, action: .dismiss) {
              TextState("Cancel")
            }
          } message: {
            TextState("This will close all terminal sessions.")
          }
          return pendingFDEffect
        #else
          return .concatenate(
            pendingFDEffect,
            .run { @MainActor _ in
              NSApplication.shared.terminate(nil)
            })
        #endif

      case .newTerminal:
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          return .none
        }
        analyticsClient.capture("terminal_tab_created", nil)
        let shouldRunSetupScript = state.repositories.pendingSetupScriptWorktreeIDs.contains(worktree.id)
        return .run { _ in
          await terminalClient.send(.createTab(worktree, runSetupScriptIfNew: shouldRunSetupScript))
        }

      case .jumpToLatestUnread:
        guard let location = terminalClient.latestUnreadNotification() else {
          jumpLogger.debug("jumpToLatestUnread invoked with no unread notifications.")
          return .none
        }
        guard let worktree = state.repositories.worktree(for: location.worktreeID) else {
          jumpLogger.warning(
            "jumpToLatestUnread: worktree \(location.worktreeID) vanished between notification lookup and dispatch."
          )
          return .none
        }
        analyticsClient.capture("notifications_jump_to_latest_unread", nil)
        // `.merge` is safe here: `focusSurface` carries the `Worktree`
        // explicitly, so it does not depend on `selectWorktree` landing
        // first. `.concatenate` would serialize unnecessarily.
        return .merge(
          .send(.repositories(.selectWorktree(location.worktreeID, focusTerminal: true))),
          .run { _ in
            await terminalClient.send(
              .focusSurface(worktree, tabID: location.tabID, surfaceID: location.surfaceID)
            )
            await terminalClient.markNotificationRead(location.worktreeID, location.notificationID)
          }
        )

      case .runScript:
        // Find the selected or primary script and run it.
        guard let definition = state.primaryScript else {
          // No scripts configured — open repository scripts settings.
          guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
            return .none
          }
          let repositoryID = worktree.repositoryRootURL.path(percentEncoded: false)
          return .send(.settings(.setSelection(.repositoryScripts(repositoryID))))
        }
        return .send(.runNamedScript(definition))

      case .runNamedScript(let definition):
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          return .none
        }
        // Prevent running the same script twice.
        guard !state.runningScriptIDs.contains(definition.id) else { return .none }
        let trimmed = definition.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        analyticsClient.capture("script_run", ["kind": definition.kind.rawValue])
        var ids = state.repositories.runningScriptsByWorktreeID[worktree.id] ?? [:]
        ids[definition.id] = definition.resolvedTintColor
        state.repositories.runningScriptsByWorktreeID[worktree.id] = ids
        return .run { _ in
          await terminalClient.send(
            .runBlockingScript(worktree, kind: .script(definition), script: definition.command)
          )
        }

      case .stopScript(let definition):
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.stopScript(worktree, definitionID: definition.id))
        }

      case .stopRunScripts:
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.stopRunScript(worktree))
        }

      case .closeTab:
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          return .none
        }
        analyticsClient.capture("terminal_tab_closed", nil)
        return .run { _ in
          await terminalClient.send(.closeFocusedTab(worktree))
        }

      case .closeSurface:
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.closeFocusedSurface(worktree))
        }

      case .startSearch:
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.startSearch(worktree))
        }

      case .searchSelection:
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.searchSelection(worktree))
        }

      case .navigateSearchNext:
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.navigateSearchNext(worktree))
        }

      case .navigateSearchPrevious:
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.navigateSearchPrevious(worktree))
        }

      case .endSearch:
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.endSearch(worktree))
        }

      case .settings(.repositorySettings(.delegate(.settingsChanged(let rootURL)))):
        guard let selectedWorktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID),
          selectedWorktree.repositoryRootURL == rootURL
        else {
          return .none
        }
        let worktreeID = selectedWorktree.id
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        return .send(.worktreeSettingsLoaded(repositorySettings, worktreeID: worktreeID))

      case .worktreeSettingsLoaded(let settings, let worktreeID):
        guard state.repositories.selectedWorktreeID == worktreeID else {
          return .none
        }
        @Shared(.settingsFile) var settingsFile
        let normalizedDefaultEditorID = OpenWorktreeAction.normalizedDefaultEditorID(
          settingsFile.global.defaultEditorID
        )
        state.openActionSelection = OpenWorktreeAction.fromSettingsID(
          settings.openActionID,
          defaultEditorID: normalizedDefaultEditorID
        )
        state.scripts = settings.scripts
        return .none

      case .deeplinkReceived(let url, let source, let responseFD):
        let deeplinkClient = deeplinkClient
        guard let parsed = deeplinkClient.parse(url) else {
          deeplinkLogger.warning("Failed to parse deeplink URL: \(url)")
          // Close the socket FD with an error so the CLI doesn't hang.
          if let responseFD {
            return sendSocketResponse(
              clientFD: responseFD, ok: false, error: "Invalid deeplink: \(url.absoluteString)")
          }
          if url.scheme == "supacode" {
            state.alert = AlertState {
              TextState("Invalid deeplink")
            } actions: {
              ButtonState(role: .cancel, action: .dismiss) {
                TextState("OK")
              }
            } message: {
              TextState("The deeplink URL could not be recognized: \(url.absoluteString)")
            }
          }
          return .none
        }
        guard state.repositories.isInitialLoadComplete else {
          // Socket commands arriving before load is complete get an immediate error
          // since pendingDeeplinks stores parsed Deeplink values without the socket
          // FD, and replaying them later would leave the CLI client hanging.
          if let responseFD {
            return sendSocketResponse(
              clientFD: responseFD, ok: false, error: "Supacode is still loading. Try again.")
          }
          state.pendingDeeplinks.append(parsed)
          return .none
        }
        return .send(.deeplink(parsed, source: source, responseFD: responseFD))

      case .deeplink(let deeplink, let source, let responseFD):
        let alertBefore = state.alert
        let effect = handleDeeplink(deeplink, source: source, responseFD: responseFD, state: &state)
        guard let responseFD else { return effect }
        // Confirmation dialog pending — response will be sent when dialog resolves.
        guard state.deeplinkInputConfirmation == nil else { return effect }
        // If a new alert was set during handling, the command failed.
        let succeeded = state.alert == alertBefore
        let errorMessage: String? = succeeded ? nil : extractAlertMessage(state.alert)
        return .concatenate(
          effect,
          sendSocketResponse(
            clientFD: responseFD, ok: succeeded, error: errorMessage))

      case .deeplinkReferenceOpened:
        state.isDeeplinkReferenceRequested = false
        return .none

      case .systemNotificationsPermissionFailed(let errorMessage):
        return .concatenate(
          .send(.settings(.setSystemNotificationsEnabled(false))),
          .send(.settings(.showNotificationPermissionAlert(errorMessage: errorMessage)))
        )

      case .alert(.dismiss):
        state.alert = nil
        return .none

      case .alert(.presented(.confirmQuit)):
        analyticsClient.capture("app_quit", nil)
        let pendingFDEffect = drainPendingResponseFD(state: &state, error: "Supacode is quitting.")
        state.alert = nil
        return .concatenate(
          pendingFDEffect,
          .run { @MainActor _ in
            NSApplication.shared.terminate(nil)
          })

      case .alert:
        return .none

      case .deeplinkInputConfirmation(
        .presented(.delegate(.confirm(let worktreeID, let confirmedAction, let alwaysAllow)))):
        let pendingFD = state.deeplinkInputConfirmation?.responseFD
        state.deeplinkInputConfirmation = nil
        // The initial deeplink dispatch already selected the worktree via
        // `handleWorktreeDeeplink`. Re-dispatch only the action effect, skipping
        // the redundant select.
        let alertBefore = state.alert
        let actionEffect = worktreeActionEffect(
          worktreeID: worktreeID,
          action: confirmedAction,
          state: &state,
          bypassConfirmation: true,
        )
        let succeeded = state.alert == alertBefore
        let responseEffect: Effect<Action> =
          pendingFD.map {
            sendSocketResponse(
              clientFD: $0,
              ok: succeeded,
              error: succeeded ? nil : extractAlertMessage(state.alert))
          } ?? .none
        let policyEffect: Effect<Action> =
          alwaysAllow
          ? .send(.settings(.setAutomatedActionPolicy(.always)))
          : .none
        return .concatenate(policyEffect, actionEffect, responseEffect)

      case .deeplinkInputConfirmation(.presented(.delegate(.cancel))):
        let pendingFD = state.deeplinkInputConfirmation?.responseFD
        state.deeplinkInputConfirmation = nil
        guard let clientFD = pendingFD else { return .none }
        return sendSocketResponse(clientFD: clientFD, ok: false, error: "Cancelled by user.")

      case .deeplinkInputConfirmation(.dismiss):
        // Drain any pending responseFD when TCA auto-dismisses the dialog
        // so the CLI client does not hang.
        return drainPendingResponseFD(state: &state, error: "Dialog dismissed.")

      case .deeplinkInputConfirmation:
        return .none

      case .repositories(.repositoriesLoaded), .repositories(.openRepositoriesFinished):
        // Flush pending deeplinks after initial load completes, even when repositoriesChanged
        // delegate does not fire (e.g., zero repos loaded with no state change).
        guard !state.pendingDeeplinks.isEmpty else { return .none }
        let pending = state.pendingDeeplinks
        state.pendingDeeplinks.removeAll()
        return .merge(pending.map { .send(.deeplink($0)) })

      case .repositories:
        return .none

      case .settings:
        return .none

      case .updates:
        return .none

      case .commandPalette(.delegate(.selectWorktree(let worktreeID))):
        return .send(.repositories(.selectWorktree(worktreeID)))

      case .commandPalette(.delegate(.checkForUpdates)):
        return .send(.updates(.checkForUpdates))

      case .commandPalette(.delegate(.openSettings)):
        return .send(.settings(.setSelection(.general)))

      case .commandPalette(.delegate(.newWorktree)):
        return .send(.repositories(.createRandomWorktree))

      case .commandPalette(.delegate(.openRepository)):
        return .send(.repositories(.setOpenPanelPresented(true)))

      case .commandPalette(.delegate(.removeWorktree(let worktreeID, let repositoryID))):
        return .send(
          .repositories(
            .requestDeleteSidebarItems([
              RepositoriesFeature.DeleteWorktreeTarget(
                worktreeID: worktreeID, repositoryID: repositoryID)
            ])))

      case .commandPalette(.delegate(.archiveWorktree(let worktreeID, let repositoryID))):
        return .send(.repositories(.requestArchiveWorktree(worktreeID, repositoryID)))

      case .commandPalette(.delegate(.viewArchivedWorktrees)):
        return .send(.repositories(.selectArchivedWorktrees))

      case .commandPalette(.delegate(.refreshWorktrees)):
        return .send(.repositories(.refreshWorktrees))

      case .commandPalette(.delegate(.ghosttyCommand(let action))):
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.performBindingAction(worktree, action: action))
        }

      case .commandPalette(.delegate(.openPullRequest(let worktreeID))):
        return .send(.repositories(.pullRequestAction(worktreeID, .openOnGithub)))

      case .commandPalette(.delegate(.markPullRequestReady(let worktreeID))):
        return .send(.repositories(.pullRequestAction(worktreeID, .markReadyForReview)))

      case .commandPalette(.delegate(.mergePullRequest(let worktreeID))):
        return .send(.repositories(.pullRequestAction(worktreeID, .merge)))

      case .commandPalette(.delegate(.closePullRequest(let worktreeID))):
        return .send(.repositories(.pullRequestAction(worktreeID, .close)))

      case .commandPalette(.delegate(.copyFailingJobURL(let worktreeID))):
        return .send(.repositories(.pullRequestAction(worktreeID, .copyFailingJobURL)))

      case .commandPalette(.delegate(.copyCiFailureLogs(let worktreeID))):
        return .send(.repositories(.pullRequestAction(worktreeID, .copyCiFailureLogs)))

      case .commandPalette(.delegate(.rerunFailedJobs(let worktreeID))):
        return .send(.repositories(.pullRequestAction(worktreeID, .rerunFailedJobs)))

      case .commandPalette(.delegate(.openFailingCheckDetails(let worktreeID))):
        return .send(.repositories(.pullRequestAction(worktreeID, .openFailingCheckDetails)))

      case .commandPalette(.delegate(.runScript(let definition))):
        return .send(.runNamedScript(definition))

      case .commandPalette(.delegate(.stopScript(let scriptID, _))):
        // If a script was removed from settings while still running,
        // it won't appear here. That is intentional — the terminal
        // tab stays open and cleans up on natural completion or when
        // the user closes the tab manually.
        guard let definition = state.scripts.first(where: { $0.id == scriptID }) else {
          return .none
        }
        return .send(.stopScript(definition))

      #if DEBUG
        case .commandPalette(.delegate(.debugTestToast(let toast))):
          return .send(.repositories(.showToast(toast)))
      #endif

      case .commandPalette:
        return .none

      case .terminalEvent(.notificationReceived(let worktreeID, let surfaceID, let title, let body)):
        var effects: [Effect<Action>] = [
          .send(.repositories(.worktreeNotificationReceived(worktreeID)))
        ]
        if state.settings.systemNotificationsEnabled {
          let deeplinkURL = surfaceDeeplinkURL(worktreeID: worktreeID, surfaceID: surfaceID)
          effects.append(
            .run { _ in
              await systemNotificationClient.send(title, body, deeplinkURL)
            }
          )
        }
        if state.settings.notificationSoundEnabled && !state.settings.systemNotificationsEnabled {
          effects.append(
            .run { _ in
              await notificationSoundClient.play()
            }
          )
        }
        return .merge(effects)

      case .terminalEvent(.notificationIndicatorChanged(let count)):
        state.notificationIndicatorCount = count
        return .run { _ in
          await MainActor.run {
            NSApplication.shared.dockTile.badgeLabel = nil
          }
        }

      case .terminalEvent(.commandPaletteToggleRequested(let worktreeID)):
        if state.commandPalette.isPresented {
          return .send(.commandPalette(.setPresented(false)))
        }
        return .merge(
          .send(.repositories(.selectWorktree(worktreeID))),
          .send(.commandPalette(.setPresented(true)))
        )
      case .terminalEvent(.setupScriptConsumed(let worktreeID)):
        return .send(.repositories(.consumeSetupScript(worktreeID)))

      case .terminalEvent(.blockingScriptCompleted(let worktreeID, let kind, let exitCode, let tabId)):
        switch kind {
        case .script(let definition):
          return .send(
            .repositories(
              .scriptCompleted(
                worktreeID: worktreeID,
                scriptID: definition.id,
                kind: kind,
                exitCode: exitCode,
                tabId: tabId
              )
            )
          )
        case .archive:
          return .send(.repositories(.archiveScriptCompleted(worktreeID: worktreeID, exitCode: exitCode, tabId: tabId)))
        case .delete:
          return .send(.repositories(.deleteScriptCompleted(worktreeID: worktreeID, exitCode: exitCode, tabId: tabId)))
        }

      case .terminalEvent:
        return .none
      }
    }
    core
    Scope(state: \.repositories, action: \.repositories) {
      RepositoriesFeature()
    }
    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }
    Scope(state: \.updates, action: \.updates) {
      UpdatesFeature()
    }
    Scope(state: \.commandPalette, action: \.commandPalette) {
      CommandPaletteFeature()
    }
    .ifLet(\.$deeplinkInputConfirmation, action: \.deeplinkInputConfirmation) {
      DeeplinkInputConfirmationFeature()
    }
  }

  // MARK: - Open worktree.

  private enum OpenWorktreeSource: String {
    case toolbar
    case contextMenu
    case revealInFinder
  }

  private func openWorktreeEffect(
    worktree: Worktree,
    action: OpenWorktreeAction,
    source: OpenWorktreeSource,
    state: State
  ) -> Effect<Action> {
    analyticsClient.capture("worktree_opened", ["action": action.settingsID, "source": source.rawValue])
    guard action == .editor else {
      return .run { send in
        await workspaceClient.open(action, worktree) { error in
          send(.openWorktreeFailed(error))
        }
      }
    }
    let shouldRunSetupScript =
      state.repositories.pendingSetupScriptWorktreeIDs.contains(worktree.id)
    return .run { _ in
      await terminalClient.send(
        .createTabWithInput(
          worktree,
          input: "$EDITOR",
          runSetupScriptIfNew: shouldRunSetupScript
        )
      )
    }
  }

  // MARK: - Deeplink handling.

  // MARK: Deeplink dispatch.

  private func handleDeeplink(
    _ deeplink: Deeplink,
    source: ActionSource = .urlScheme,
    responseFD: Int32? = nil,
    state: inout State
  ) -> Effect<Action> {
    switch deeplink {
    case .open:
      return .run { @MainActor _ in
        let app = NSApplication.shared
        guard let window = app.windows.first(where: { $0.identifier?.rawValue == WindowID.main })
        else {
          app.activate()
          return
        }
        if window.isMiniaturized {
          window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        app.activate()
      }
    case .help:
      state.isDeeplinkReferenceRequested = true
      return .none
    case .worktree(let worktreeID, let action):
      return handleWorktreeDeeplink(
        worktreeID: worktreeID, action: action, source: source, responseFD: responseFD, state: &state
      )
    case .repoOpen(let path):
      return .send(.repositories(.openRepositories([path])))
    case .repoWorktreeNew(let repositoryID, let branch, let baseRef, let fetchOrigin):
      guard let repository = state.repositories.repositories[id: repositoryID] else {
        deeplinkLogger.warning("Repository not found: \(repositoryID)")
        state.alert = AlertState {
          TextState("Repository not found")
        } actions: {
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("OK")
          }
        } message: {
          TextState("No repository matching the deeplink could be found.")
        }
        return .none
      }
      // Worktree creation is git-only. Reject the deeplink with a
      // clear alert when it targets a folder rather than letting the
      // request fall into `createWorktreeStream`.
      guard repository.isGitRepository else {
        deeplinkLogger.warning(
          "Ignoring repoWorktreeNew deeplink for folder repository: \(repositoryID)"
        )
        state.alert = AlertState {
          TextState("Worktrees not available")
        } actions: {
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("OK")
          }
        } message: {
          TextState("Worktrees are only supported for git repositories.")
        }
        return .none
      }
      guard let branch else {
        return .send(.repositories(.createRandomWorktreeInRepository(repositoryID)))
      }
      return .send(
        .repositories(
          .createWorktreeInRepository(
            repositoryID: repositoryID,
            nameSource: .explicit(branch),
            baseRefSource: baseRef.map { .explicit($0) } ?? .repositorySetting,
            fetchOrigin: fetchOrigin,
          )
        )
      )
    case .settings(let section):
      return handleSettingsDeeplink(section: section)
    case .settingsRepo(let repositoryID):
      guard let repository = state.repositories.repositories[id: repositoryID] else {
        deeplinkLogger.warning("Repository not found for settings deeplink: \(repositoryID)")
        state.alert = AlertState {
          TextState("Repository not found")
        } actions: {
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("OK")
          }
        } message: {
          TextState("No repository matching the deeplink could be found.")
        }
        return .none
      }
      // Folders have no general settings pane — send them to the
      // scripts page (the only settings surface that applies).
      let section: SettingsSection =
        repository.isGitRepository ? .repository(repositoryID) : .repositoryScripts(repositoryID)
      return .send(.settings(.setSelection(section)))
    }
  }

  // MARK: Worktree deeplink dispatch.

  private func handleWorktreeDeeplink(
    worktreeID rawWorktreeID: Worktree.ID,
    action: Deeplink.WorktreeAction,
    source: ActionSource = .urlScheme,
    responseFD: Int32? = nil,
    state: inout State,
    bypassConfirmation: Bool = false
  ) -> Effect<Action> {
    let worktreeID = resolveWorktreeID(rawWorktreeID, state: state)
    guard state.repositories.worktree(for: worktreeID) != nil else {
      deeplinkLogger.warning("Worktree not found: \(rawWorktreeID)")
      state.alert = worktreeNotFoundAlert()
      return .none
    }
    // Folders expose the worktree deeplink surface only for the
    // actions that actually apply — select, open terminals, delete,
    // run scripts. `.archive` / `.unarchive` / `.pin` / `.unpin`
    // make no sense for a folder's synthetic main worktree, so
    // reject them explicitly rather than silently no-op-ing.
    if let folderRepoID = state.repositories.repositoryID(for: worktreeID),
      let folderRepo = state.repositories.repositories[id: folderRepoID],
      !folderRepo.isGitRepository
    {
      let incompatibleAction: RepositoriesFeature.FolderIncompatibleAction?
      switch action {
      case .archive: incompatibleAction = .archive
      case .unarchive: incompatibleAction = .unarchive
      case .pin: incompatibleAction = .pin
      case .unpin: incompatibleAction = .unpin
      default: incompatibleAction = nil
      }
      if let incompatibleAction {
        // Copy shared with the in-reducer folder hotkey handlers
        // via `FolderIncompatibleAction.alertCopy`. The
        // `AlertState<_>` type diverges (this feature's `Alert`
        // has its own action surface) so the struct itself can't
        // be shared, but the title / message strings live in one
        // place and can't drift between entry points.
        let copy = incompatibleAction.alertCopy
        state.alert = AlertState {
          TextState(copy.title)
        } actions: {
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("OK")
          }
        } message: {
          TextState(copy.message)
        }
        return .none
      }
    }

    let policyBypass = state.settings.automatedActionPolicy.allowsBypass(from: source)
    let selectEffect: Effect<Action> =
      .send(.repositories(.selectWorktree(worktreeID, focusTerminal: true)))
    let actionEffect = worktreeActionEffect(
      worktreeID: worktreeID,
      action: action,
      state: &state,
      bypassConfirmation: bypassConfirmation || policyBypass,
      responseFD: responseFD,
    )
    return .concatenate(selectEffect, actionEffect)
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func worktreeActionEffect(
    worktreeID: Worktree.ID,
    action: Deeplink.WorktreeAction,
    state: inout State,
    bypassConfirmation: Bool,
    responseFD: Int32? = nil
  ) -> Effect<Action> {
    switch action {
    case .select:
      return .none
    case .run:
      return .send(.runScript)
    case .stop:
      return .send(.stopRunScripts)
    case .runScript(let scriptID):
      return runScriptDeeplinkEffect(
        worktreeID: worktreeID,
        scriptID: scriptID,
        state: &state,
        bypassConfirmation: bypassConfirmation,
        responseFD: responseFD
      )
    case .stopScript(let scriptID):
      return stopScriptDeeplinkEffect(worktreeID: worktreeID, scriptID: scriptID, state: &state)
    case .archive:
      guard let repositoryID = resolveRepositoryID(for: worktreeID, label: "archive", state: &state) else {
        return .none
      }
      return .send(.repositories(.requestArchiveWorktree(worktreeID, repositoryID)))
    case .unarchive:
      return .send(.repositories(.unarchiveWorktree(worktreeID)))
    case .delete:
      return deeplinkDeleteWorktreeEffect(
        worktreeID: worktreeID,
        action: action,
        state: &state,
        bypassConfirmation: bypassConfirmation,
        responseFD: responseFD
      )
    case .pin:
      return .send(.repositories(.pinWorktree(worktreeID)))
    case .unpin:
      return .send(.repositories(.unpinWorktree(worktreeID)))
    case .tab(let tabID):
      guard validateTab(worktreeID: worktreeID, tabID: tabID, state: &state) else { return .none }
      return sendTerminalCommand(worktreeID: worktreeID, state: state) { worktree in
        .selectTab(worktree, tabID: TerminalTabID(rawValue: tabID))
      }
    case .tabNew(let input, let id):
      // Reject explicit IDs that collide with an existing tab.
      if let id, terminalClient.tabExists(worktreeID, TerminalTabID(rawValue: id)) {
        state.alert = AlertState {
          TextState("Tab ID already exists")
        } actions: {
          ButtonState(role: .cancel, action: .dismiss) { TextState("OK") }
        } message: {
          TextState("A tab with ID \(id.uuidString) already exists.")
        }
        return .none
      }
      guard let input, !input.isEmpty else {
        return sendTerminalCommand(worktreeID: worktreeID, state: state) { worktree in
          .createTab(worktree, runSetupScriptIfNew: true, id: id)
        }
      }
      if requiresInputConfirmation(state: state, bypassConfirmation: bypassConfirmation) {
        return presentDeeplinkConfirmation(
          worktreeID: worktreeID, responseFD: responseFD, message: .command(input),
          action: action, state: &state)
      }
      return sendTerminalCommand(worktreeID: worktreeID, state: state) { worktree in
        .createTabWithInput(worktree, input: input, runSetupScriptIfNew: false, id: id)
      }
    case .tabDestroy(let tabID):
      guard validateTab(worktreeID: worktreeID, tabID: tabID, state: &state) else { return .none }
      guard bypassConfirmation else {
        return presentDeeplinkConfirmation(
          worktreeID: worktreeID,
          responseFD: responseFD,
          message: .confirmation("Close tab \(tabID.uuidString.prefix(8))…?"),
          action: action,
          state: &state)
      }
      return sendTerminalCommand(worktreeID: worktreeID, state: state) { worktree in
        .destroyTab(worktree, tabID: TerminalTabID(rawValue: tabID))
      }
    case .surface(let tabID, let surfaceID, let input):
      guard validateSurface(worktreeID: worktreeID, tabID: tabID, surfaceID: surfaceID, state: &state) else {
        return .none
      }
      if let input, !input.isEmpty,
        requiresInputConfirmation(state: state, bypassConfirmation: bypassConfirmation)
      {
        return presentDeeplinkConfirmation(
          worktreeID: worktreeID, responseFD: responseFD, message: .command(input),
          action: action, state: &state)
      }
      return sendTerminalCommand(worktreeID: worktreeID, state: state) { worktree in
        .focusSurface(worktree, tabID: TerminalTabID(rawValue: tabID), surfaceID: surfaceID, input: input)
      }
    case .surfaceSplit(let tabID, let surfaceID, let direction, let input, let id):
      guard validateSurface(worktreeID: worktreeID, tabID: tabID, surfaceID: surfaceID, state: &state) else {
        return .none
      }
      // Reject explicit IDs that collide with an existing surface across all tabs.
      if let id, terminalClient.surfaceExistsInWorktree(worktreeID, id) {
        state.alert = AlertState {
          TextState("Surface ID already exists")
        } actions: {
          ButtonState(role: .cancel, action: .dismiss) { TextState("OK") }
        } message: {
          TextState("A surface with ID \(id.uuidString) already exists.")
        }
        return .none
      }
      if let input, !input.isEmpty,
        requiresInputConfirmation(state: state, bypassConfirmation: bypassConfirmation)
      {
        return presentDeeplinkConfirmation(
          worktreeID: worktreeID, responseFD: responseFD, message: .command(input),
          action: action, state: &state)
      }
      return sendTerminalCommand(worktreeID: worktreeID, state: state) { worktree in
        .splitSurface(
          worktree, tabID: TerminalTabID(rawValue: tabID), surfaceID: surfaceID,
          direction: direction, input: input, id: id)
      }
    case .surfaceDestroy(let tabID, let surfaceID):
      guard validateSurface(worktreeID: worktreeID, tabID: tabID, surfaceID: surfaceID, state: &state) else {
        return .none
      }
      guard bypassConfirmation else {
        return presentDeeplinkConfirmation(
          worktreeID: worktreeID,
          responseFD: responseFD,
          message: .confirmation("Close surface \(surfaceID.uuidString.prefix(8))…?"),
          action: action,
          state: &state)
      }
      return sendTerminalCommand(worktreeID: worktreeID, state: state) { worktree in
        .destroySurface(worktree, tabID: TerminalTabID(rawValue: tabID), surfaceID: surfaceID)
      }
    }
  }

  private func runScriptDeeplinkEffect(
    worktreeID: Worktree.ID,
    scriptID: UUID,
    state: inout State,
    bypassConfirmation: Bool,
    responseFD: Int32?
  ) -> Effect<Action> {
    // Read the target worktree's scripts directly so cross-worktree
    // deeplinks do not depend on the currently selected worktree's
    // `state.scripts`, which may still reflect an older selection.
    guard let worktree = state.repositories.worktree(for: worktreeID) else {
      state.alert = worktreeNotFoundAlert()
      return .none
    }
    @SharedReader(.repositorySettings(worktree.repositoryRootURL)) var repositorySettings
    guard let definition = repositorySettings.scripts.first(where: { $0.id == scriptID }) else {
      state.alert = scriptAlert(
        title: "Script not found",
        message: "No script matching the deeplink could be found. It may have been removed."
      )
      return .none
    }
    let trimmed = definition.command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      state.alert = scriptAlert(
        title: "Script has no command",
        message: "\"\(definition.displayName)\" has an empty command. Configure it in Settings first."
      )
      return .none
    }
    let runningIDs = state.repositories.runningScriptsByWorktreeID[worktreeID] ?? [:]
    guard runningIDs[scriptID] == nil else {
      state.alert = scriptAlert(
        title: "Script already running",
        message: "\"\(definition.displayName)\" is already running in this worktree."
      )
      return .none
    }
    if requiresInputConfirmation(state: state, bypassConfirmation: bypassConfirmation) {
      return presentDeeplinkConfirmation(
        worktreeID: worktreeID,
        responseFD: responseFD,
        message: .command(definition.command),
        action: .runScript(scriptID: scriptID),
        state: &state
      )
    }
    analyticsClient.capture("script_run", ["kind": definition.kind.rawValue])
    var updated = runningIDs
    updated[scriptID] = definition.resolvedTintColor
    state.repositories.runningScriptsByWorktreeID[worktreeID] = updated
    let terminalClient = terminalClient
    return .run { _ in
      await terminalClient.send(
        .runBlockingScript(worktree, kind: .script(definition), script: definition.command)
      )
    }
  }

  private func stopScriptDeeplinkEffect(
    worktreeID: Worktree.ID,
    scriptID: UUID,
    state: inout State
  ) -> Effect<Action> {
    guard let worktree = state.repositories.worktree(for: worktreeID) else {
      state.alert = worktreeNotFoundAlert()
      return .none
    }
    @SharedReader(.repositorySettings(worktree.repositoryRootURL)) var repositorySettings
    guard let definition = repositorySettings.scripts.first(where: { $0.id == scriptID }) else {
      state.alert = scriptAlert(
        title: "Script not found",
        message: "No script matching the deeplink could be found. It may have been removed."
      )
      return .none
    }
    let runningIDs = state.repositories.runningScriptsByWorktreeID[worktreeID] ?? [:]
    guard runningIDs[scriptID] != nil else {
      state.alert = scriptAlert(
        title: "Script not running",
        message: "\"\(definition.displayName)\" is not currently running in this worktree."
      )
      return .none
    }
    let terminalClient = terminalClient
    return .run { _ in
      await terminalClient.send(.stopScript(worktree, definitionID: scriptID))
    }
  }

  private func scriptAlert(title: String, message: String) -> AlertState<Alert> {
    AlertState {
      TextState(title)
    } actions: {
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("OK")
      }
    } message: {
      TextState(message)
    }
  }

  private func worktreeNotFoundAlert() -> AlertState<Alert> {
    AlertState {
      TextState("Worktree not found")
    } actions: {
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("OK")
      }
    } message: {
      TextState("No worktree matching the deeplink could be found. It may have been removed.")
    }
  }

  private func deeplinkDeleteWorktreeEffect(
    worktreeID: Worktree.ID,
    action: Deeplink.WorktreeAction,
    state: inout State,
    bypassConfirmation: Bool,
    responseFD: Int32? = nil
  ) -> Effect<Action> {
    guard let repositoryID = resolveRepositoryID(for: worktreeID, label: "delete", state: &state) else {
      return .none
    }
    // Folder repos have a synthesized main-worktree whose
    // `workingDirectory == rootURL`, so `isMainWorktree(worktree)`
    // is true by geometry — rejecting them here would show a
    // misleading "main worktree" alert and prevent folders from
    // ever being removed via deeplink. Route folder targets to
    // `.requestDeleteSidebarItems([target])` so the 3-button folder
    // alert pipeline (Remove / Delete / Cancel) handles the
    // confirmation and the batch aggregator drains normally.
    let repository = state.repositories.repositories[id: repositoryID]
    let isFolder = repository?.isGitRepository == false
    if let worktree = state.repositories.worktree(for: worktreeID),
      state.repositories.isMainWorktree(worktree),
      !isFolder
    {
      state.alert = AlertState {
        TextState("Delete not allowed")
      } actions: {
        ButtonState(role: .cancel, action: .dismiss) {
          TextState("OK")
        }
      } message: {
        TextState("Deleting the main worktree is not allowed.")
      }
      return .none
    }
    let target = RepositoriesFeature.DeleteWorktreeTarget(
      worktreeID: worktreeID, repositoryID: repositoryID
    )
    if isFolder {
      // Folders always surface the 3-button confirmation so users
      // can pick between `.folderUnlink` (drop from sidebar, stay
      // on disk) and `.folderTrash` (move to Trash). The deeplink
      // `bypassConfirmation` flag still shows it — there's no
      // reasonable default disposition for folders.
      return .send(.repositories(.requestDeleteSidebarItems([target])))
    }
    let worktreeName = state.repositories.worktree(for: worktreeID)?.name ?? worktreeID
    guard bypassConfirmation else {
      return presentDeeplinkConfirmation(
        worktreeID: worktreeID,
        responseFD: responseFD,
        message: .confirmation("Delete worktree \"\(worktreeName)\"?"),
        action: action,
        state: &state
      )
    }
    return .send(.repositories(.deleteSidebarItemConfirmed(worktreeID, repositoryID)))
  }

  private func resolveRepositoryID(
    for worktreeID: Worktree.ID,
    label: String,
    state: inout State
  ) -> Repository.ID? {
    guard let repositoryID = state.repositories.repositoryID(containing: worktreeID) else {
      deeplinkLogger.warning("Repository not found for worktree \(worktreeID) during \(label)")
      state.alert = AlertState {
        TextState("\(label.capitalized) failed")
      } actions: {
        ButtonState(role: .cancel, action: .dismiss) {
          TextState("OK")
        }
      } message: {
        TextState("Could not resolve the repository for this worktree.")
      }
      return nil
    }
    return repositoryID
  }

  // MARK: Confirmation helpers.

  /// Returns `true` when confirmation has not been bypassed (via policy or re-dispatch).
  private func requiresInputConfirmation(
    state: State,
    bypassConfirmation: Bool
  ) -> Bool {
    !bypassConfirmation
  }

  // MARK: Terminal command dispatch.

  private func sendTerminalCommand(
    worktreeID: Worktree.ID,
    state: State,
    command: (Worktree) -> TerminalClient.Command
  ) -> Effect<Action> {
    guard let worktree = state.repositories.worktree(for: worktreeID) else {
      deeplinkLogger.warning("Worktree \(worktreeID) vanished before terminal command could be dispatched.")
      return .none
    }
    let cmd = command(worktree)
    let terminalClient = terminalClient
    return .run { _ in await terminalClient.send(cmd) }
  }

  /// Extracts a human-readable message from an alert state for CLI error responses.
  private func extractAlertMessage(_ alert: AlertState<Alert>?) -> String {
    guard let alert else { return "Command failed." }
    // TextState.customDumpValue returns the plain string for verbatim content.
    let raw =
      (alert.message?.customDumpValue as? String)
      ?? (alert.title.customDumpValue as? String)
    return raw?.isEmpty == false ? raw! : "Command failed."
  }

  /// Sends a socket response on the given FD and closes it.
  private func sendSocketResponse(
    clientFD: Int32,
    ok succeeded: Bool,
    error: String? = nil
  ) -> Effect<Action> {
    .run { _ in
      AgentHookSocketServer.sendCommandResponse(clientFD: clientFD, ok: succeeded, error: error)
    }
  }

  /// Closes any pending `responseFD` stored in the confirmation dialog so the CLI does not hang.
  private func drainPendingResponseFD(
    state: inout State,
    error: String
  ) -> Effect<Action> {
    guard let clientFD = state.deeplinkInputConfirmation?.responseFD else { return .none }
    state.deeplinkInputConfirmation?.responseFD = nil
    return sendSocketResponse(clientFD: clientFD, ok: false, error: error)
  }

  private func presentDeeplinkConfirmation(
    worktreeID: Worktree.ID,
    responseFD: Int32? = nil,
    message: DeeplinkConfirmationMessage,
    action: Deeplink.WorktreeAction,
    state: inout State
  ) -> Effect<Action> {
    let worktreeName = state.repositories.worktree(for: worktreeID)?.name ?? "Unknown"
    let repoName = state.repositories.repositoryID(containing: worktreeID)
      .flatMap { state.repositories.repositories[id: $0]?.name }
    // Close any previously pending FD so the CLI does not hang.
    let supersededEffect: Effect<Action> =
      state.deeplinkInputConfirmation?.responseFD.map {
        sendSocketResponse(clientFD: $0, ok: false, error: "Superseded by another command.")
      } ?? .none
    state.deeplinkInputConfirmation = DeeplinkInputConfirmationFeature.State(
      worktreeID: worktreeID,
      worktreeName: worktreeName,
      repositoryName: repoName,
      message: message,
      action: action,
      responseFD: responseFD
    )
    return supersededEffect
  }

  // MARK: Validation helpers.

  /// Validates that a tab exists in the given worktree, showing an alert if not.
  private func validateTab(
    worktreeID: Worktree.ID,
    tabID: UUID,
    state: inout State
  ) -> Bool {
    guard terminalClient.tabExists(worktreeID, TerminalTabID(rawValue: tabID)) else {
      deeplinkLogger.warning("Tab \(tabID) not found in worktree \(worktreeID)")
      state.alert = AlertState {
        TextState("Tab not found")
      } actions: {
        ButtonState(role: .cancel, action: .dismiss) {
          TextState("OK")
        }
      } message: {
        TextState("No tab matching the deeplink could be found. It may have been closed.")
      }
      return false
    }
    return true
  }

  /// Validates that a tab and surface exist in the given worktree, showing an alert if not.
  private func validateSurface(
    worktreeID: Worktree.ID,
    tabID: UUID,
    surfaceID: UUID,
    state: inout State
  ) -> Bool {
    guard validateTab(worktreeID: worktreeID, tabID: tabID, state: &state) else { return false }
    guard terminalClient.surfaceExists(worktreeID, TerminalTabID(rawValue: tabID), surfaceID) else {
      deeplinkLogger.warning("Surface \(surfaceID) not found in tab \(tabID) of worktree \(worktreeID)")
      state.alert = AlertState {
        TextState("Surface not found")
      } actions: {
        ButtonState(role: .cancel, action: .dismiss) {
          TextState("OK")
        }
      } message: {
        TextState("No surface matching the deeplink could be found. It may have been closed.")
      }
      return false
    }
    return true
  }

  /// Resolves a worktree ID, trying the raw value first then appending a trailing
  /// slash since stored IDs derived from `standardizedFileURL` for directories include one.
  private func resolveWorktreeID(
    _ rawID: Worktree.ID,
    state: State
  ) -> Worktree.ID {
    guard state.repositories.worktree(for: rawID) == nil else { return rawID }
    let alternate = rawID + "/"
    guard state.repositories.worktree(for: alternate) != nil else { return rawID }
    return alternate
  }

  // MARK: Settings deeplink.

  private func handleSettingsDeeplink(section: Deeplink.DeeplinkSettingsSection?) -> Effect<Action> {
    guard let section else {
      return .send(.settings(.setSelection(.general)))
    }
    let settingsSection: SettingsSection =
      switch section {
      case .general: .general
      case .notifications: .notifications
      case .worktrees: .worktree
      case .developer, .codingAgents: .developer
      case .shortcuts: .shortcuts
      case .updates: .updates
      case .github: .github
      }
    return .send(.settings(.setSelection(settingsSection)))
  }

  /// Builds a `supacode://worktree/<id>/surface/<tabID>/<surfaceID>` URL for a
  /// notification whose surface is known; falls back to the worktree-level
  /// URL when the tab containing the surface can no longer be resolved.
  private func surfaceDeeplinkURL(worktreeID: Worktree.ID, surfaceID: UUID) -> URL? {
    let percentEncodingSet = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "/"))
    let encodedWorktreeID =
      worktreeID.addingPercentEncoding(withAllowedCharacters: percentEncodingSet) ?? worktreeID
    guard let tabID = terminalClient.tabID(worktreeID, surfaceID) else {
      notificationsLogger.debug(
        "Surface \(surfaceID) is no longer attached to a tab in \(worktreeID); "
          + "degrading tap deeplink to the worktree root."
      )
      return urlOrWarn(
        "supacode://worktree/\(encodedWorktreeID)",
        worktreeID: worktreeID,
        surfaceID: surfaceID
      )
    }
    let tabRaw = tabID.rawValue.uuidString
    let surfaceRaw = surfaceID.uuidString
    return urlOrWarn(
      "supacode://worktree/\(encodedWorktreeID)/tab/\(tabRaw)/surface/\(surfaceRaw)",
      worktreeID: worktreeID,
      surfaceID: surfaceID
    )
  }

  private func urlOrWarn(_ string: String, worktreeID: Worktree.ID, surfaceID: UUID) -> URL? {
    guard let url = URL(string: string) else {
      notificationsLogger.warning(
        "Failed to build deeplink URL for worktree \(worktreeID) surface \(surfaceID) from: \(string)"
      )
      return nil
    }
    return url
  }
}
