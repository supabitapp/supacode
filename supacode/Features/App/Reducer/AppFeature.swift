import AppKit
import ComposableArchitecture
import Foundation
import OrderedCollections
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
  static let backgroundPersist = "app.backgroundPersist"
  static let agentPresencePersist = "app.agentPresencePersist"
  /// Watchdog for a deferred completion ack, keyed by the open client fd and
  /// its generation so a recycled fd gets a distinct cancellation id.
  static func commandAck(_ responseFD: Int32, _ token: Int) -> String {
    "app.commandAck.\(responseFD).\(token)"
  }
  /// Watchdog for a socket-backed confirmation dialog left open, so its fd
  /// times out instead of lingering until the user acts.
  static let deeplinkConfirmationTimeout = "app.deeplinkConfirmationTimeout"
}

/// Default seconds the app holds a socket connection open waiting for a
/// command to complete before draining it with a timeout error. Overridden
/// per command by the `timeout` deeplink query item the CLI embeds.
private nonisolated let defaultCommandTimeoutSeconds = 180

@Reducer
struct AppFeature {
  @ObservableState
  struct State: Equatable {
    var agentPresence = AgentPresenceFeature.State()
    var repositories: RepositoriesFeature.State
    var settings: SettingsFeature.State
    var updates = UpdatesFeature.State()
    var commandPalette = CommandPaletteFeature.State()
    /// Terminal-orchestration state. Owns the per-tab feature collection so
    /// tab-bar views scope through `\.terminals` (narrow) instead of the full
    /// app store. Mirrors sidebar's `RepositoriesFeature` ownership pattern.
    var terminals = TerminalsFeature.State()
    var openActionSelection: OpenWorktreeAction = .finder
    var repoScripts: [ScriptDefinition] = []
    var globalScripts: [ScriptDefinition] = []
    var notificationIndicatorCount: Int = 0
    // Cached aggregate from the terminal manager; flips only on the global
    // any-surface boundary so menu / action gates avoid sidebarItems iteration.
    var hasAnyTerminalSurface: Bool = false
    var lastKnownSystemNotificationsEnabled: Bool
    var lastKnownAgentPresenceBadgesEnabled: Bool
    var pendingDeeplinks: [Deeplink] = []
    var isDeeplinkReferenceRequested = false
    /// Cached projection of every primitive the menu-bar `WorktreeCommands`
    /// body reads. The menu observes ONE Equatable field instead of pulling
    /// `\.repositories` / `\.settings` (whole-substate) observation through
    /// `_modify`, which previously made every per-row mutation rebuild the
    /// system menu and drop hover state (#289).
    var worktreeMenuSnapshot: WorktreeMenuSnapshot = .init()
    @Presents var alert: AlertState<Alert>?
    @Presents var deeplinkInputConfirmation: DeeplinkInputConfirmationFeature.State?
    /// CLI socket commands whose ack is deferred until the operation is
    /// observably complete, keyed by the open client fd. A watchdog drains each
    /// on timeout so the fd never leaks.
    var pendingCommandAcks: IdentifiedArrayOf<PendingCommandAck> = []
    /// Monotonic generation stamped on each pending ack so a stale watchdog can
    /// never drain a different ack that recycled the same client fd number.
    var commandAckGeneration: Int = 0
    /// Monotonic generation stamped on each socket-backed confirmation so a stale
    /// timeout action can't fire against a dialog that recycled the same fd.
    var confirmationGeneration: Int = 0

    init(
      repositories: RepositoriesFeature.State = .init(),
      settings: SettingsFeature.State = .init()
    ) {
      self.repositories = repositories
      self.settings = settings
      lastKnownSystemNotificationsEnabled = settings.systemNotificationsEnabled
      lastKnownAgentPresenceBadgesEnabled = settings.agentPresenceBadgesEnabled
      // Seed from settings so `state.allScripts` doesn't start empty before the
      // first `settingsChanged` delegate fires. Globals aren't worktree-scoped,
      // so deselection (line below in `selectedWorktreeChanged(nil)`)
      // intentionally does not clear them.
      globalScripts = settings.globalScripts
      // Warm the cache so the first state mutation doesn't churn the snapshot
      // and trip every TestStore expectation that omits a state-change closure.
      worktreeMenuSnapshot = computeWorktreeMenuSnapshot()
    }

    /// Repo scripts followed by global scripts; repo wins on ID collisions.
    var allScripts: [ScriptDefinition] {
      .merged(repo: repoScripts, global: globalScripts)
    }

    /// Canonical script for `id` honoring "repo wins on collision". Returns
    /// `nil` if the script was deleted between palette / view binding and dispatch.
    func resolveScript(id: UUID) -> ScriptDefinition? {
      allScripts.first { $0.id == id }
    }

    /// The script that the primary toolbar button should run.
    var primaryScript: ScriptDefinition? {
      allScripts.primaryScript
    }

    /// Running script IDs for the currently selected worktree. Sourced from
    /// the cached slice so an agent storm on the focused row doesn't pull
    /// observation through `sidebarItems[id:]`.
    var runningScriptIDs: Set<UUID> {
      Set(repositories.selectedWorktreeSlice?.runningScripts.ids ?? [])
    }

    /// Whether any `.run`-kind script is currently running in the selected worktree.
    var hasRunningRunScript: Bool {
      allScripts.hasRunningRunScript(in: runningScriptIDs)
    }
  }

  /// A CLI socket command whose response is held open until the operation
  /// completes. `id` is the open client fd (unique while the connection lives).
  struct PendingCommandAck: Equatable, Sendable, Identifiable {
    var id: Int32 { responseFD }
    let responseFD: Int32
    /// Generation stamp; the watchdog only drains when it still matches.
    let token: Int
    var match: CompletionMatch
  }

  /// What a deferred ack is waiting for, with the key that correlates the
  /// completion signal back to the originating command.
  enum CompletionMatch: Equatable, Sendable {
    /// tab new: resolves when the worktree's new tab projection carries `tabID`.
    case tabInWorktree(worktreeID: Worktree.ID, tabID: UUID)
    /// surface split: resolves when the worktree's tab projection lists `surfaceID`.
    case surfaceSplit(worktreeID: Worktree.ID, surfaceID: UUID)
    /// repo worktree-new: `pendingID` (supplied by the deeplink so it flows back
    /// through the creation stream) correlates the exact creation even when
    /// several run concurrently in one repo; `worktreeID` is nil until that
    /// worktree is created, then its first tab resolves the ack.
    case worktreeNew(pendingID: Worktree.ID, worktreeID: Worktree.ID?)
    /// tab close.
    case tabRemoved(worktreeID: Worktree.ID, tabID: TerminalTabID)
    /// surface close (scoped by worktree so a duplicate id elsewhere can't cross-resolve).
    case surfaceClosed(worktreeID: Worktree.ID, surfaceID: UUID)
    /// worktree delete (git worktree removed).
    case worktreeRemoved(worktreeID: Worktree.ID)
    /// folder-repository delete (the folder is removed from Supacode / disk).
    case folderRemoved(repositoryID: Repository.ID)
  }

  enum Action {
    case agentPresence(AgentPresenceFeature.Action)
    case terminals(TerminalsFeature.Action)
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
    case requestTerminateAllTerminalSessions
    case newTerminal
    case selectTerminalTabAtIndex(Int)
    case splitTerminal(TerminalSplitMenuDirection)
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
    case deeplink(
      Deeplink, source: ActionSource = .urlScheme, responseFD: Int32? = nil,
      timeoutSeconds: Int = defaultCommandTimeoutSeconds)
    case commandAckTimedOut(responseFD: Int32, token: Int)
    case deeplinkConfirmationTimedOut(responseFD: Int32, token: Int)
    case deeplinkReferenceOpened
    case alert(PresentationAction<Alert>)
    case deeplinkInputConfirmation(PresentationAction<DeeplinkInputConfirmationFeature.Action>)
    case terminalEvent(TerminalClient.Event)
  }

  enum Alert: Equatable {
    case dismiss
    case confirmQuit
    case confirmQuitAndTerminate
    case confirmTerminateAllTerminalSessions
  }

  @Dependency(AnalyticsClient.self) private var analyticsClient
  @Dependency(AppLifecycleClient.self) private var appLifecycleClient
  @Dependency(DeeplinkClient.self) private var deeplinkClient
  @Dependency(RepositoryPersistenceClient.self) private var repositoryPersistence
  @Dependency(WorkspaceClient.self) private var workspaceClient
  @Dependency(NotificationSoundClient.self) private var notificationSoundClient
  @Dependency(SystemNotificationClient.self) private var systemNotificationClient
  @Dependency(TerminalClient.self) private var terminalClient
  @Dependency(WorktreeInfoWatcherClient.self) private var worktreeInfoWatcher
  @Dependency(\.continuousClock) private var clock

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
          },
          .run { send in
            // Reap crash / force-quit orphans, then resurrect agent badges
            // from embedded records. Races with `.task` under `.merge`; the
            // `repositoriesChanged` handler drains layout-seeded surfaces if restore wins.
            @SharedReader(.layouts) var layouts: [String: TerminalLayoutSnapshot] = [:]
            let known = Set(layouts.values.flatMap { $0.allSurfaceIDs })
            let staged = AgentPresenceFeature.stageRestore(fromLayouts: layouts.values)
            await terminalClient.reapOrphanSessions(known)
            await send(.agentPresence(.restoreFromSnapshot(staged: staged)))
          }
        )

      case .agentPresence(.delegate(.surfacesChanged(let surfaces))):
        // Persist on every presence delta, debounced, so a crash mid-session
        // doesn't lose the most recent agent state. The save only touches
        // worktrees with a live `WorktreeTerminalState`, so it can't write
        // rows the user hasn't selected yet.
        let agentsBySurface = state.agentPresence.agentsBySurface()
        return .merge(
          agentPresenceFanOutEffect(surfaces: surfaces, state: state),
          .run { [clock] _ in
            try await clock.sleep(for: .seconds(1))
            await MainActor.run {
              terminalClient.saveLayoutsWithAgents(agentsBySurface)
            }
          }
          .cancellable(id: CancelID.agentPresencePersist, cancelInFlight: true)
        )

      case .agentPresence:
        return .none

      case .scenePhaseChanged(let phase):
        switch phase {
        case .active:
          analyticsClient.capture("app_activated", nil)
          return .merge(
            .send(.repositories(.refreshWorktrees)),
            // Re-probe agent integrations on activation so the sidebar
            // card reflects external installs (e.g. `claude install`)
            // for users who keep the app open across days.
            .send(.settings(.refreshAgentIntegrationStates)),
            .run { send in
              while !Task.isCancelled {
                try? await ContinuousClock().sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await send(.repositories(.refreshWorktrees))
              }
            }
            .cancellable(id: CancelID.periodicRefresh, cancelInFlight: true)
          )
        case .background:
          // Snapshot on the way out so a force-quit / crash doesn't drop
          // running-agent state before `applicationWillTerminate` fires.
          // Coalesce so rapid Cmd+Tab churn writes once per 1s burst.
          let agentsBySurface = state.agentPresence.agentsBySurface()
          return .merge(
            .cancel(id: CancelID.periodicRefresh),
            .run { [clock] _ in
              try await clock.sleep(for: .seconds(1))
              await MainActor.run {
                terminalClient.saveLayoutsWithAgents(agentsBySurface)
              }
            }
            .cancellable(id: CancelID.backgroundPersist, cancelInFlight: true)
          )
        case .inactive:
          return .cancel(id: CancelID.periodicRefresh)
        @unknown default:
          return .cancel(id: CancelID.periodicRefresh)
        }

      case .repositories(.delegate(.selectedWorktreeChanged(let worktree))):
        let lastFocusedWorktreeID = worktree?.id
        guard let worktree else {
          state.openActionSelection = .finder
          state.repoScripts = []
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
        @Shared(.repositorySettings(rootURL, host: worktree.host)) var repositorySettings
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
          state.repositories.sidebarItems[id: worktree.id]?.lifecycle == .pending
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
        RepositoriesFeature.syncSidebar(&state.repositories)
        let archivedIDs = state.repositories.archivedWorktreeIDSet
        let allowed = Set(
          state.repositories.sidebarItems
            .filter { item in
              !archivedIDs.contains(item.id) || item.lifecycle == .deletingScript
            }
            .map(\.id)
        )
        let recencyIDs = CommandPaletteFeature.recencyRetentionIDs(
          from: repositories,
          scripts: state.allScripts
        )
        let worktrees = state.repositories.worktreesForInfoWatcher()
        var effects: [Effect<Action>] = []
        effects.append(contentsOf: [
          .send(
            .settings(
              .repositoriesChanged(
                repositories.map {
                  SettingsRepositorySummary(
                    id: $0.id.rawValue,
                    name: $0.name,
                    isGitRepository: $0.isGitRepository,
                    host: $0.host,
                    rootURL: $0.rootURL
                  )
                }
              )
            )
          ),
          .send(.commandPalette(.pruneRecency(recencyIDs))),
          .run { _ in
            await worktreeInfoWatcher.send(.setWorktrees(worktrees))
          },
        ])
        // Don't prune terminal state while remote repos are still resolving:
        // their placeholders have no rows yet, so pruning would delete restored
        // remote layouts and kill their zmx sessions before resolution lands.
        if state.repositories.resolvingRemoteRepositoryIDs.isEmpty {
          // Failed/loading repos have no worktree rows yet, so shield their restored zmx sessions from prune.
          // Environment-blocked git repos are suppressed with no rows either, so shield them too: a transient
          // license/tools gate must not tear down their live terminal layouts.
          let protectedRepositoryIDs = Set(state.repositories.loadFailuresByID.keys)
            .union(state.repositories.environmentBlockedRepositoryIDs)
          effects.append(
            .run { [allowed, protectedRepositoryIDs] _ in
              await terminalClient.send(
                .prune(keeping: allowed, protectingRepositoryIDs: protectedRepositoryIDs)
              )
            }
          )
        }
        // Drain layout-seeded surfaces (including any that piled up from prior
        // reconciles before this delegate fired) so restored presence records
        // light up rows born on this tick.
        let pendingRehydrate = state.repositories.pendingAgentRehydrateSurfaces
        state.repositories.pendingAgentRehydrateSurfaces.removeAll()
        let rehydrate = pendingRehydrate.intersection(state.agentPresence.bySurface.keys)
        if !rehydrate.isEmpty {
          effects.append(agentPresenceFanOutEffect(surfaces: rehydrate, state: state))
        }
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
          repository.isGitRepository ? .repository(repositoryID.rawValue) : .repositoryScripts(repositoryID.rawValue)
        return .send(.settings(.setSelection(section)))

      case .repositories(.delegate(.runBlockingScript(let worktree, _, let kind, let script))):
        // Defense-in-depth against a future emitter forgetting the pre-screen.
        if worktree.isMissing {
          appLogger.info("Skipping \(kind) blocking script on missing worktree \(worktree.id)")
          return .none
        }
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
        let agentBadgesFlipped =
          settings.agentPresenceBadgesEnabled != state.lastKnownAgentPresenceBadgesEnabled
        state.lastKnownAgentPresenceBadgesEnabled = settings.agentPresenceBadgesEnabled
        // Compare IDs as a set — name/command edits and pure reorders should not re-prune recency.
        let globalScriptIDsChanged = Set(state.globalScripts.map(\.id)) != Set(settings.globalScripts.map(\.id))
        state.globalScripts = settings.globalScripts
        if let selectedWorktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) {
          let rootURL = selectedWorktree.repositoryRootURL
          @Shared(.repositorySettings(rootURL, host: selectedWorktree.host)) var repositorySettings
          state.openActionSelection = OpenWorktreeAction.fromSettingsID(
            repositorySettings.openActionID,
            defaultEditorID: settings.defaultEditorID
          )
        }
        var effects: [Effect<Action>] = [
          .send(.repositories(.setGithubIntegrationEnabled(settings.githubIntegrationEnabled))),
          .send(.repositories(.setMergedWorktreeAction(settings.mergedWorktreeAction))),
          .send(.repositories(.setMoveNotifiedWorktreeToTop(settings.moveNotifiedWorktreeToTop))),
          .send(
            .repositories(.setAutoDeleteArchivedWorktreesAfterDays(settings.autoDeleteArchivedWorktreesAfterDays))
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
          },
        ]
        if globalScriptIDsChanged {
          effects.append(pruneScriptRecencyEffect(state: state))
        }
        if agentBadgesFlipped {
          effects.append(
            agentPresenceBadgesToggledEffect(
              badgesEnabled: settings.agentPresenceBadgesEnabled,
              state: state
            )
          )
        }
        return .merge(effects)

      case .openActionSelectionChanged(let action):
        state.openActionSelection = action
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          appLogger.warning("openActionSelectionChanged: selected worktree not found, skipping persistence.")
          return .none
        }
        let rootURL = worktree.repositoryRootURL
        let actionID = action.settingsID
        @Shared(.repositorySettings(rootURL, host: worktree.host)) var repositorySettings
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
        let mode = state.settings.confirmQuitMode
        let needsConfirmation: Bool =
          switch mode {
          case .never: false
          case .always: true
          case .auto: hasActiveWorkBlockingQuit(state: state)
          }
        guard needsConfirmation else {
          return quitEffect(state: &state, terminateSessions: state.settings.terminateSessionsOnQuit)
        }
        state.alert = quitConfirmationAlert(
          terminateOnQuit: state.settings.terminateSessionsOnQuit,
          hasBlockingScripts: terminalClient.hasInflightBlockingScripts()
        )
        // Without surfacing the main window, an alert raised from Cmd+Q
        // when no window is up has no scene to anchor to and `terminate()`
        // sits behind an invisible dialog.
        return .run { @MainActor _ in NSApplication.shared.surfaceMainWindow() }

      case .alert(.presented(.confirmQuit)):
        state.alert = nil
        return quitEffect(state: &state, terminateSessions: state.settings.terminateSessionsOnQuit)

      case .alert(.presented(.confirmQuitAndTerminate)):
        state.alert = nil
        return quitEffect(state: &state, terminateSessions: true)

      case .requestTerminateAllTerminalSessions:
        state.alert = AlertState {
          TextState("Terminate All Terminal Sessions?")
        } actions: {
          ButtonState(role: .cancel, action: .dismiss) { TextState("Cancel") }
          ButtonState(role: .destructive, action: .confirmTerminateAllTerminalSessions) {
            TextState("Terminate Sessions")
          }
        } message: {
          TextState(
            "Every terminal tab will be closed and every background shell stopped. "
              + "Running scripts will be lost."
          )
        }
        return .run { @MainActor _ in NSApplication.shared.surfaceMainWindow() }

      case .alert(.presented(.confirmTerminateAllTerminalSessions)):
        state.alert = nil
        analyticsClient.capture("terminal_sessions_terminated_via_menu", nil)
        return .run { _ in
          await terminalClient.terminateAllSessions()
        }

      case .newTerminal:
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID),
          !worktree.isMissing
        else {
          return .none
        }
        analyticsClient.capture("terminal_tab_created", nil)
        let shouldRunSetupScript =
          state.repositories.sidebarItems[id: worktree.id]?.lifecycle == .pending
        return .run { _ in
          await terminalClient.send(.createTab(worktree, runSetupScriptIfNew: shouldRunSetupScript))
        }

      case .selectTerminalTabAtIndex(let tabNumber):
        // Works regardless of first responder (menu key-equivalent), so ⌘-number
        // switches tabs even when the sidebar holds focus. The index is clamped to
        // the last tab inside the terminal state.
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID),
          !worktree.isMissing
        else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.selectTabAtIndex(worktree, index: tabNumber))
        }

      case .splitTerminal(let direction):
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID),
          !worktree.isMissing
        else {
          return .none
        }
        return .run { _ in
          await terminalClient.send(.performBindingAction(worktree, action: direction.ghosttyBinding))
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
          guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
            return .none
          }
          // Globals-only setup → land on the global pane the user actually configured.
          if state.repoScripts.isEmpty, !state.globalScripts.isEmpty {
            return .send(.settings(.setSelection(.scripts)))
          }
          let repositoryID =
            state.repositories.repositoryID(containing: worktree.id)?.rawValue
            ?? worktree.repositoryRootURL.path(percentEncoded: false)
          return .send(.settings(.setSelection(.repositoryScripts(repositoryID))))
        }
        return .send(.runNamedScript(definition))

      case .runNamedScript(let incoming):
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID),
          !worktree.isMissing
        else {
          return .none
        }
        // Re-resolve so a stale view binding can't bypass repo-wins or run a since-deleted script.
        guard let definition = state.resolveScript(id: incoming.id) else { return .none }
        // Prevent running the same script twice.
        guard !state.runningScriptIDs.contains(definition.id) else { return .none }
        let trimmed = definition.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          // Empty-command resolve (only reachable today via the palette's "Configure: …"
          // entry) — route to the right settings pane so the user can finish setup.
          let isGlobal =
            state.globalScripts.contains { $0.id == definition.id }
            && !state.repoScripts.contains { $0.id == definition.id }
          if isGlobal {
            return .send(.settings(.setSelection(.scripts)))
          }
          let repositoryID =
            state.repositories.repositoryID(containing: worktree.id)?.rawValue
            ?? worktree.repositoryRootURL.path(percentEncoded: false)
          return .send(.settings(.setSelection(.repositoryScripts(repositoryID))))
        }
        analyticsClient.capture("script_run", ["kind": definition.kind.rawValue])
        let tint = definition.resolvedTintColor
        var effects: [Effect<Action>] = [
          .run { _ in
            await terminalClient.send(
              .runBlockingScript(worktree, kind: .script(definition), script: definition.command)
            )
          }
        ]
        if state.repositories.sidebarItems[id: worktree.id] != nil {
          effects.append(
            .send(
              .repositories(
                .sidebarItems(
                  .element(id: worktree.id, action: .runningScriptStarted(id: definition.id, tint: tint))
                )
              )
            )
          )
        }
        return .merge(effects)

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

      case .settings(.repositorySettings(.delegate(.settingsChanged(let rootURL, let host)))):
        guard let selectedWorktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID),
          selectedWorktree.repositoryRootURL == rootURL,
          selectedWorktree.host == host
        else {
          return .none
        }
        let worktreeID = selectedWorktree.id
        @Shared(.repositorySettings(rootURL, host: host)) var repositorySettings
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
        state.repoScripts = settings.scripts
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
        let timeoutSeconds = Self.parseTimeoutSeconds(from: url)
        return .send(
          .deeplink(parsed, source: source, responseFD: responseFD, timeoutSeconds: timeoutSeconds))

      case .deeplink(let deeplink, let source, let responseFD, let timeoutSeconds):
        let alertBefore = state.alert
        let effect = handleDeeplink(
          deeplink, source: source, responseFD: responseFD,
          timeoutSeconds: timeoutSeconds, state: &state)
        guard let responseFD else { return effect }
        // Confirmation dialog pending; response will be sent when dialog resolves.
        guard state.deeplinkInputConfirmation == nil else { return effect }
        // A completion-based ack was registered; it resolves when the operation finishes.
        guard state.pendingCommandAcks[id: responseFD] == nil else { return effect }
        // If a new alert was set during handling, the command failed.
        let succeeded = state.alert == alertBefore
        let errorMessage: String? = succeeded ? nil : extractAlertMessage(state.alert)
        return .concatenate(
          effect,
          sendSocketResponse(
            clientFD: responseFD, ok: succeeded, error: errorMessage))

      case .commandAckTimedOut(let responseFD, let token):
        // Ignore a stale watchdog whose ack was already resolved (and whose fd
        // may have been recycled by a newer ack with a different token).
        guard let ack = state.pendingCommandAcks[id: responseFD], ack.token == token else {
          return .none
        }
        state.pendingCommandAcks.remove(id: responseFD)
        return sendSocketResponse(
          clientFD: ack.responseFD, ok: false,
          error: "Timed out waiting for the operation to complete.")

      case .deeplinkConfirmationTimedOut(let responseFD, let token):
        // Ignore a stale watchdog whose dialog was already resolved (and whose fd
        // may have been recycled by a newer dialog with a different token).
        guard let confirmation = state.deeplinkInputConfirmation,
          confirmation.responseFD == responseFD, confirmation.timeoutToken == token
        else { return .none }
        state.deeplinkInputConfirmation = nil
        return sendSocketResponse(
          clientFD: responseFD, ok: false, error: "Timed out waiting for confirmation.")

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

      case .alert:
        return .none

      case .deeplinkInputConfirmation(
        .presented(.delegate(.confirm(let worktreeID, let confirmedAction, let alwaysAllow)))):
        let pendingFD = state.deeplinkInputConfirmation?.responseFD
        let timeoutSeconds =
          state.deeplinkInputConfirmation?.timeoutSeconds ?? defaultCommandTimeoutSeconds
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
          responseFD: pendingFD,
          timeoutSeconds: timeoutSeconds,
        )
        let succeeded = state.alert == alertBefore
        let responseEffect: Effect<Action>
        if let pendingFD, state.pendingCommandAcks[id: pendingFD] != nil {
          // Completion-based ack registered; it resolves when the operation finishes.
          responseEffect = .none
        } else if let pendingFD {
          responseEffect = sendSocketResponse(
            clientFD: pendingFD,
            ok: succeeded,
            error: succeeded ? nil : extractAlertMessage(state.alert))
        } else {
          responseEffect = .none
        }
        let policyEffect: Effect<Action> =
          alwaysAllow
          ? .send(.settings(.setAutomatedActionPolicy(.always)))
          : .none
        return .concatenate(
          .cancel(id: CancelID.deeplinkConfirmationTimeout),
          policyEffect, actionEffect, responseEffect)

      case .deeplinkInputConfirmation(.presented(.delegate(.cancel))):
        let pendingFD = state.deeplinkInputConfirmation?.responseFD
        state.deeplinkInputConfirmation = nil
        let cancelWatchdog: Effect<Action> = .cancel(id: CancelID.deeplinkConfirmationTimeout)
        guard let clientFD = pendingFD else { return cancelWatchdog }
        return .merge(
          cancelWatchdog,
          sendSocketResponse(clientFD: clientFD, ok: false, error: "Cancelled by user."))

      case .deeplinkInputConfirmation(.dismiss):
        // Drain any pending responseFD when TCA auto-dismisses the dialog
        // so the CLI client does not hang.
        return .merge(
          .cancel(id: CancelID.deeplinkConfirmationTimeout),
          drainPendingResponseFD(state: &state, error: "Dialog dismissed."))

      case .deeplinkInputConfirmation:
        return .none

      case .repositories(.createRandomWorktreeSucceeded(let worktree, _, let pendingID)):
        // Bind this creation's ack (matched by its pending id) to the real
        // worktree id so its first tab resolves it.
        bindWorktreeNewAck(pendingID: pendingID, to: worktree.id, state: &state)
        return .none

      case .repositories(.createRandomWorktreeFailed(_, let message, let pendingID, _, _, _, _)):
        return resolveCommandAcks(ok: false, error: message, state: &state) { match in
          if case .worktreeNew(let ackPendingID, _) = match { return ackPendingID == pendingID }
          return false
        }

      case .repositories(.cliWorktreeAckCancelled(let pendingID)):
        // The creation prompt was cancelled before it produced a worktree.
        return resolveCommandAcks(
          ok: false, error: "Worktree creation cancelled.", state: &state
        ) { match in
          if case .worktreeNew(let ackPendingID, _) = match { return ackPendingID == pendingID }
          return false
        }

      case .repositories(.worktreeDeleted(let worktreeID, _, _, _)):
        return resolveCommandAcks(ok: true, state: &state) { match in
          if case .worktreeRemoved(let ackWorktree) = match { return ackWorktree == worktreeID }
          return false
        }

      case .repositories(.repositoryRemovalCompleted(let repoID, let outcome, _)):
        // Resolve a folder-delete ack once removal concludes (the single action
        // that fires for both success and every failure mode).
        let succeeded: Bool
        let error: String?
        switch outcome {
        case .success:
          succeeded = true
          error = nil
        case .failureSilent:
          succeeded = false
          error = "Delete did not complete."
        case .failureWithMessage(let message):
          succeeded = false
          error = message
        }
        return resolveCommandAcks(ok: succeeded, error: error, state: &state) { match in
          if case .folderRemoved(let ackRepoID) = match { return ackRepoID == repoID }
          return false
        }

      case .repositories(.alert(.dismiss)):
        // A pre-confirmation cancel drains the folder ack; one already past
        // confirmation (its repo is removing) resolves on repositoryRemovalCompleted,
        // so an unrelated dismissal must not drain it.
        let removingRepoIDs = Set(state.repositories.removingRepositoryIDs.keys)
        return resolveCommandAcks(ok: false, error: "Cancelled by user.", state: &state) { match in
          if case .folderRemoved(let ackRepoID) = match { return !removingRepoIDs.contains(ackRepoID) }
          return false
        }

      case .repositories(.deleteWorktreeFailed(let message, let worktreeID)):
        return resolveCommandAcks(ok: false, error: message, state: &state) { match in
          if case .worktreeRemoved(let ackWorktree) = match { return ackWorktree == worktreeID }
          return false
        }

      case .repositories(.deleteScriptCompleted(let worktreeID, let exitCode, _)):
        // Exit 0 proceeds to removal (resolved by `.worktreeDeleted`); a failed or
        // cancelled delete has no removal to follow, so resolve the ack now.
        guard exitCode != 0 else { return .none }
        let message =
          exitCode.map { "Delete script failed (exit code \($0))." } ?? "Delete cancelled."
        return resolveCommandAcks(ok: false, error: message, state: &state) { match in
          if case .worktreeRemoved(let ackWorktree) = match { return ackWorktree == worktreeID }
          return false
        }

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

      case .commandPalette(.delegate(.addRemoteRepository)):
        return .send(.repositories(.requestAddRemoteRepository))

      case .commandPalette(.delegate(.removeWorktree(let worktreeID, let repositoryID))):
        return .send(
          .repositories(
            .requestDeleteSidebarItems([
              RepositoriesFeature.DeleteWorktreeTarget(
                worktreeID: worktreeID, repositoryID: repositoryID)
            ])))

      case .commandPalette(.delegate(.archiveWorktree(let worktreeID, let repositoryID))):
        return .send(.repositories(.requestArchiveWorktree(worktreeID, repositoryID)))

      case .commandPalette(.delegate(.renameBranch(let worktreeID, let repositoryID))):
        return .send(.repositories(.requestRenameBranch(worktreeID, repositoryID)))

      case .commandPalette(.delegate(.viewArchivedWorktrees)):
        return .send(.repositories(.selectArchivedWorktrees))

      case .commandPalette(.delegate(.refreshWorktrees)):
        return .send(.repositories(.refreshWorktrees))

      case .commandPalette(.delegate(.ghosttyCommand(let action))):
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          return .none
        }
        // Ghostty void actions emit bare tag names; no colon.
        let command: TerminalClient.Command
        if action == "prompt_surface_title" || action == "prompt_tab_title" {
          // Capture the focused tab synchronously so a fast tab switch between dispatch
          // and effect execution can't redirect the rename to the wrong tab.
          let tabID = terminalClient.selectedTabID(worktree.id)
          command = .beginTabRename(worktree, tabID: tabID)
        } else if let surfaceID = terminalClient.selectedSurfaceID(worktree.id) {
          command = .performBindingActionOnSurface(worktree, surfaceID: surfaceID, action: action)
        } else {
          command = .performBindingAction(worktree, action: action)
        }
        return .run { _ in
          await terminalClient.send(command)
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
        guard let definition = state.allScripts.first(where: { $0.id == scriptID }) else {
          return .none
        }
        return .send(.stopScript(definition))

      #if DEBUG
        case .commandPalette(.delegate(.debugTestToast(let toast))):
          return .send(.repositories(.showToast(toast)))
      #endif

      case .commandPalette:
        return .none

      case .terminalEvent(
        .notificationReceived(let worktreeID, let surfaceID, let title, let body, let isViewed)):
        var effects: [Effect<Action>] = [
          .send(.repositories(.worktreeNotificationReceived(worktreeID)))
        ]
        let isMuted = isViewed && state.settings.muteNotificationsForActiveSurface
        if state.settings.systemNotificationsEnabled && !isMuted {
          let deeplinkURL = surfaceDeeplinkURL(worktreeID: worktreeID, surfaceID: surfaceID)
          effects.append(
            .run { _ in
              await systemNotificationClient.send(title, body, deeplinkURL)
            }
          )
        }
        if state.settings.notificationSound != .never && !state.settings.systemNotificationsEnabled && !isMuted {
          let sound = state.settings.notificationSound
          effects.append(
            .run { _ in
              await notificationSoundClient.play(sound)
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

      case .terminalEvent(.terminalHasAnySurfaceChanged(let hasAny)):
        state.hasAnyTerminalSurface = hasAny
        return .none

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

      case .terminalEvent(.worktreeProjectionChanged(let worktreeID, let projection)):
        guard let row = state.repositories.sidebarItems[id: worktreeID] else { return .none }
        // Re-fan-out only for surfaces this projection ADDS to the row;
        // steady-state churn (notification arrival, focus changes) keeps the
        // surfaceIDs set stable and skips this entirely.
        let addedSurfaces = Set(projection.surfaceIDs).subtracting(row.surfaceIDs)
        let restoredAddedSurfaces: Set<UUID> =
          addedSurfaces.isEmpty || state.agentPresence.bySurface.isEmpty
          ? []
          : addedSurfaces.filter { state.agentPresence.bySurface[$0] != nil }
        let projectionEffect: Effect<Action> = .send(
          .repositories(
            .sidebarItems(
              .element(id: worktreeID, action: .terminalProjectionChanged(projection))
            )
          )
        )
        guard !restoredAddedSurfaces.isEmpty else { return projectionEffect }
        // Keep the delegate hop here: `projectionEffect` must apply
        // `terminalProjectionChanged` first so the fan-out reads the updated
        // `surfaceIDs`. A direct `agentPresenceFanOutEffect(...)` would
        // capture pre-projection state and miss the new surface.
        return .concatenate(
          projectionEffect,
          .send(.agentPresence(.delegate(.surfacesChanged(restoredAddedSurfaces))))
        )

      case .terminalEvent(.tabProjectionChanged(let worktreeID, let projection)):
        // Resolve tab-new / surface-split acks once the supplied id appears.
        let ackEffect = resolveCommandAcks(ok: true, state: &state) { match in
          switch match {
          case .tabInWorktree(let ackWorktree, let tabID):
            return ackWorktree == worktreeID && projection.tabID.rawValue == tabID
          case .surfaceSplit(let ackWorktree, let surfaceID):
            return ackWorktree == worktreeID && projection.surfaceIDs.contains(surfaceID)
          default:
            return false
          }
        }
        return .merge(
          .send(.terminals(.tabProjectionChanged(worktreeID: worktreeID, projection: projection))),
          ackEffect)

      case .terminalEvent(.tabCreated(let worktreeID)):
        // Resolve worktree-new acks once the new worktree's first tab exists,
        // returning the created worktree id to the CLI.
        return resolveCommandAcks(
          ok: true, resourceID: Self.percentEncodedID(worktreeID.rawValue), state: &state
        ) { match in
          if case .worktreeNew(_, let boundID?) = match { return boundID == worktreeID }
          return false
        }

      case .terminalEvent(.surfaceCreationFailed(let worktreeID, let attemptedID, let message)):
        return resolveCommandAcks(ok: false, error: message, state: &state) { match in
          switch match {
          case .tabInWorktree(let ackWorktree, let tabID):
            return ackWorktree == worktreeID && tabID == attemptedID
          case .surfaceSplit(let ackWorktree, let surfaceID):
            return ackWorktree == worktreeID && surfaceID == attemptedID
          default:
            return false
          }
        }

      case .terminalEvent(.tabRemoved(let worktreeID, let tabID)):
        let ackEffect = resolveCommandAcks(ok: true, state: &state) { match in
          if case .tabRemoved(let ackWorktree, let removed) = match {
            return ackWorktree == worktreeID && removed == tabID
          }
          return false
        }
        return .merge(
          .send(.terminals(.tabRemoved(worktreeID: worktreeID, tabID: tabID))), ackEffect)

      case .terminalEvent(.worktreeStateTornDown(let worktreeID)):
        return .send(.terminals(.worktreeStateTornDown(worktreeID: worktreeID)))

      case .terminalEvent(.tabProgressDisplayChanged(_, let tabID, let display)):
        return .send(
          .terminals(.terminalTabs(.element(id: tabID, action: .progressDisplayChanged(display))))
        )

      case .terminals:
        return .none

      case .terminalEvent(.surfacesClosed(let worktreeID, let ids)):
        guard !ids.isEmpty else { return .none }
        let ackEffect = resolveCommandAcks(ok: true, state: &state) { match in
          if case .surfaceClosed(let ackWorktree, let surfaceID) = match {
            return ackWorktree == worktreeID && ids.contains(surfaceID)
          }
          return false
        }
        let presenceEffect: Effect<Action> =
          ids.count == 1
          ? .send(.agentPresence(.surfaceClosed(ids.first!)))
          : .send(.agentPresence(.surfacesClosed(ids)))
        return .merge(presenceEffect, ackEffect)

      case .terminalEvent(.agentHookEventReceived(let event)):
        return .send(.agentPresence(.hookEventReceived(event)))

      case .terminalEvent:
        return .none
      }
    }
    core
    Scope(state: \.terminals, action: \.terminals) {
      TerminalsFeature()
    }
    Scope(state: \.agentPresence, action: \.agentPresence) {
      AgentPresenceFeature()
    }
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
    Reduce { state, action in
      // Cold-path gate. Without this, an agent storm fires
      // `recomputeWorktreeMenuSnapshotIfChanged` hundreds of times per second
      // (URL flatMap + 8-field Equatable diff each) only for the Equatable
      // diff to find a no-op. The gate skips the recompute itself for
      // actions that demonstrably can't change a snapshot input (#289).
      guard action.affectsWorktreeMenuSnapshot else { return .none }
      state.recomputeWorktreeMenuSnapshotIfChanged()
      return .none
    }
  }

  // MARK: - Agent presence fan-out.

  /// Routes `agentPresence.delegate.surfacesChanged` into per-row deltas. Each
  /// affected row gets `agentSnapshotChanged` with the badge list + activity
  /// flag; the row's `isTaskRunning` derives from `hasAgentActivity` so flipping
  /// the latter shimmers the sidebar without a separate projection dispatch.
  private func agentPresenceFanOutEffect(
    surfaces: Set<UUID>,
    state: State
  ) -> Effect<Action> {
    @Shared(.settingsFile) var settingsFile: SettingsFile
    let badgesEnabled = settingsFile.global.agentPresenceBadgesEnabled
    // Hoisted: `surfaceToItemID` is a computed property that rebuilds the dict
    // per access; reading it once keeps this loop O(surfaces) not O(rows × surfaces).
    let surfaceToItemID = state.repositories.surfaceToItemID
    var affectedRowIDs: Set<SidebarItemID> = []
    for surfaceID in surfaces {
      guard let rowID = surfaceToItemID[surfaceID] else { continue }
      affectedRowIDs.insert(rowID)
    }
    return agentSnapshotEffects(for: affectedRowIDs, state: state, badgesEnabled: badgesEnabled)
  }

  /// Re-broadcasts every row's agent snapshot under the supplied badge gate.
  /// Used when the user flips `agentPresenceBadgesEnabled`, so cached row
  /// state immediately drains or repopulates without waiting for a hook event.
  private func agentPresenceBadgesToggledEffect(
    badgesEnabled: Bool,
    state: State
  ) -> Effect<Action> {
    let rowIDs = state.repositories.sidebarItems
      .filter { !$0.surfaceIDs.isEmpty }
      .map(\.id)
    return agentSnapshotEffects(for: Set(rowIDs), state: state, badgesEnabled: badgesEnabled)
  }

  private func agentSnapshotEffects(
    for rowIDs: Set<SidebarItemID>,
    state: State,
    badgesEnabled: Bool
  ) -> Effect<Action> {
    let presence = state.agentPresence
    var effects: [Effect<Action>] = []
    var affectedSurfaces: Set<UUID> = []
    for rowID in rowIDs {
      guard let row = state.repositories.sidebarItems[id: rowID] else { continue }
      let agents = presence.agents(across: row.surfaceIDs, badgesEnabled: badgesEnabled)
      let hasActivity = presence.hasActivity(in: row.surfaceIDs)
      effects.append(
        .send(
          .repositories(
            .sidebarItems(
              .element(id: rowID, action: .agentSnapshotChanged(agents, hasActivity: hasActivity))
            )
          )
        )
      )
      affectedSurfaces.formUnion(row.surfaceIDs)
    }
    // Per-tab fanout: any tab containing an affected surface re-projects its
    // agent snapshot. Tab leaves observe `state.agents` directly so per-tab
    // mutations don't invalidate sibling tab leaves.
    for tab in state.terminals.terminalTabs
    where tab.surfaceIDs.contains(where: affectedSurfaces.contains) {
      let agents = presence.agents(across: tab.surfaceIDs, badgesEnabled: badgesEnabled)
      effects.append(
        .send(.terminals(.terminalTabs(.element(id: tab.id, action: .agentSnapshotChanged(agents)))))
      )
    }
    return .merge(effects)
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
    // Orphan rows can't be opened anywhere meaningful; bail out
    // before invoking the workspace / terminal client.
    if worktree.isMissing {
      appLogger.info("Ignoring open of missing worktree \(worktree.id) from \(source.rawValue)")
      return .none
    }
    // A remote SSH worktree opens only via an editor whose Remote-SSH CLI can
    // express the host (`remoteOpenInvocation`, shared with the UI gates). The
    // local `$EDITOR` terminal path and Finder don't apply remotely. Gated here
    // too since a hotkey can reach the reducer without the UI.
    if let host = worktree.host {
      let remotePath = worktree.location.workingDirectoryPath
      guard action != .editor,
        action.remoteOpenInvocation(host: host, remotePath: remotePath) != nil
      else {
        appLogger.info(
          "Rejecting open of remote worktree \(worktree.id) in \(action.settingsID) from \(source.rawValue)"
        )
        // A hotkey / deeplink can reach a non-capable action the UI gates out, so
        // surface why nothing opened instead of failing silently.
        return .send(.openWorktreeFailed(.remoteOpenUnsupported(action, host: host, remotePath: remotePath)))
      }
      analyticsClient.capture(
        "worktree_opened",
        ["action": action.settingsID, "source": source.rawValue, "remote": "true"]
      )
      return .run { send in
        await workspaceClient.open(action, worktree) { error in
          send(.openWorktreeFailed(error))
        }
      }
    }
    analyticsClient.capture("worktree_opened", ["action": action.settingsID, "source": source.rawValue])
    guard action == .editor else {
      return .run { send in
        await workspaceClient.open(action, worktree) { error in
          send(.openWorktreeFailed(error))
        }
      }
    }
    let shouldRunSetupScript =
      state.repositories.sidebarItems[id: worktree.id]?.lifecycle == .pending
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
    timeoutSeconds: Int = defaultCommandTimeoutSeconds,
    state: inout State
  ) -> Effect<Action> {
    switch deeplink {
    case .open:
      return .run { @MainActor _ in NSApplication.shared.surfaceMainWindow() }
    case .help:
      state.isDeeplinkReferenceRequested = true
      return .none
    case .worktree(let worktreeID, let action):
      return handleWorktreeDeeplink(
        worktreeID: worktreeID, action: action, source: source, responseFD: responseFD,
        timeoutSeconds: timeoutSeconds, state: &state
      )
    case .repoOpen(let path):
      return .send(.repositories(.openRepositories([path])))
    case .repoWorktreeNew(
      let repositoryID,
      let branch,
      let baseRef,
      let fetchOrigin,
      let worktreeName,
      let worktreePath
    ):
      return handleRepoWorktreeNewDeeplink(
        repositoryID: repositoryID, branch: branch, baseRef: baseRef, fetchOrigin: fetchOrigin,
        worktreeName: worktreeName, worktreePath: worktreePath,
        responseFD: responseFD, timeoutSeconds: timeoutSeconds, state: &state)
    case .settings(let section):
      return handleSettingsDeeplink(section: section)
    case .settingsRepo(let repositoryID):
      guard let repository = state.repositories.repositories[id: repositoryID] else {
        deeplinkLogger.warning("Repository not found for settings deeplink: \(repositoryID)")
        state.alert = repositoryNotFoundAlert()
        return .none
      }
      // Folders have no general settings pane — send them to the
      // scripts page (the only settings surface that applies).
      let section: SettingsSection =
        repository.isGitRepository ? .repository(repositoryID.rawValue) : .repositoryScripts(repositoryID.rawValue)
      return .send(.settings(.setSelection(section)))
    case .settingsRepoScripts(let repositoryID):
      guard state.repositories.repositories[id: repositoryID] != nil else {
        deeplinkLogger.warning("Repository not found for settings repo scripts deeplink: \(repositoryID)")
        state.alert = repositoryNotFoundAlert()
        return .none
      }
      return .send(.settings(.setSelection(.repositoryScripts(repositoryID.rawValue))))
    }
  }

  // MARK: Worktree-new deeplink dispatch.

  private func handleRepoWorktreeNewDeeplink(
    repositoryID: Repository.ID,
    branch: String? = nil,
    baseRef: String? = nil,
    fetchOrigin: Bool = false,
    worktreeName: String? = nil,
    worktreePath: String? = nil,
    responseFD: Int32? = nil,
    timeoutSeconds: Int = defaultCommandTimeoutSeconds,
    state: inout State
  ) -> Effect<Action> {
    guard let repository = state.repositories.repositories[id: repositoryID] else {
      deeplinkLogger.warning("Repository not found: \(repositoryID)")
      state.alert = repositoryNotFoundAlert()
      return .none
    }
    // Worktree creation is git-only. Reject a folder target with a clear alert
    // rather than letting the request fall into `createWorktreeStream`.
    guard repository.isGitRepository else {
      deeplinkLogger.warning(
        "Ignoring repoWorktreeNew deeplink for folder repository: \(repositoryID)"
      )
      state.alert = AlertState {
        TextState("Worktrees not available")
      } actions: {
        ButtonState(role: .cancel, action: .dismiss) { TextState("OK") }
      } message: {
        TextState("Worktrees are only supported for git repositories.")
      }
      return .none
    }
    if state.repositories.removingRepositoryIDs[repositoryID] != nil {
      state.alert = AlertState {
        TextState("Worktree unavailable")
      } actions: {
        ButtonState(role: .cancel, action: .dismiss) { TextState("OK") }
      } message: {
        TextState("This repository is being removed.")
      }
      return .none
    }
    // Remote creation bypasses the local pending / first-tab flow (git worktree
    // add over ssh + reload), so it has no completion signal yet and acks
    // immediately. Follow-up: give the remote create + reload its own signal.
    let isRemote = repository.host != nil
    // Correlate the CLI ack through to the new worktree's first tab via a pending
    // id stamped with the monotonic generation so concurrent creations can't
    // collide. Every local path (explicit branch, random name, the interactive
    // prompt) resolves on the first tab and returns the id.
    let pendingID: Worktree.ID?
    if !isRemote, responseFD != nil {
      state.commandAckGeneration += 1
      pendingID = WorktreeID(Self.cliPendingWorktreePrefix + "\(state.commandAckGeneration)")
    } else {
      pendingID = nil
    }
    let completionMatch: CompletionMatch? = pendingID.map {
      .worktreeNew(pendingID: $0, worktreeID: nil)
    }
    guard let branch else {
      return awaitingCompletion(
        .send(.repositories(.createRandomWorktreeInRepository(repositoryID, pendingID: pendingID))),
        match: completionMatch,
        responseFD: responseFD, timeoutSeconds: timeoutSeconds, state: &state)
    }
    let placement = WorktreePlacementOverride(
      name: worktreeName?.isEmpty == true ? nil : worktreeName,
      path: worktreePath?.isEmpty == true ? nil : worktreePath
    )
    return awaitingCompletion(
      .send(
        .repositories(
          .createWorktreeInRepository(
            repositoryID: repositoryID,
            nameSource: .explicit(branch),
            baseRefSource: baseRef.map { .explicit($0) } ?? .repositorySetting,
            fetchOrigin: fetchOrigin,
            placement: placement,
            pendingID: pendingID,
          )
        )
      ),
      match: completionMatch,
      responseFD: responseFD, timeoutSeconds: timeoutSeconds, state: &state)
  }

  // MARK: Worktree deeplink dispatch.

  private func handleWorktreeDeeplink(
    worktreeID rawWorktreeID: Worktree.ID,
    action: Deeplink.WorktreeAction,
    source: ActionSource = .urlScheme,
    responseFD: Int32? = nil,
    timeoutSeconds: Int = defaultCommandTimeoutSeconds,
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
    // actions that actually apply. `.archive` / `.unarchive` still
    // make no sense for a folder's synthetic main worktree; pin and
    // unpin now flow through the shared bucket machinery.
    if let folderRepoID = state.repositories.repositoryID(for: worktreeID),
      let folderRepo = state.repositories.repositories[id: folderRepoID],
      !folderRepo.isGitRepository
    {
      let incompatibleAction: RepositoriesFeature.FolderIncompatibleAction?
      switch action {
      case .archive: incompatibleAction = .archive
      case .unarchive: incompatibleAction = .unarchive
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
      timeoutSeconds: timeoutSeconds,
    )
    return .concatenate(selectEffect, actionEffect)
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func worktreeActionEffect(
    worktreeID: Worktree.ID,
    action: Deeplink.WorktreeAction,
    state: inout State,
    bypassConfirmation: Bool,
    responseFD: Int32? = nil,
    timeoutSeconds: Int = defaultCommandTimeoutSeconds
  ) -> Effect<Action> {
    // Block only the actions that would spawn a shell/script at the
    // missing working dir. Cleanup actions (delete/archive/pin) and
    // management of already-spawned terminals stay reachable so the
    // user can actually clear the orphan.
    let spawnsShell: Bool
    switch action {
    case .run, .runScript, .tabNew, .surfaceSplit:
      spawnsShell = true
    case .surface(_, _, let input):
      spawnsShell = input?.isEmpty == false
    case .select, .stop, .stopScript, .tab, .tabDestroy, .surfaceDestroy,
      .archive, .unarchive, .delete, .pin, .unpin:
      spawnsShell = false
    }
    if spawnsShell, let worktree = state.repositories.worktree(for: worktreeID), worktree.isMissing {
      deeplinkLogger.info(
        "Ignoring shell-spawning deeplink action on missing worktree \(worktreeID)"
      )
      // Set alert so the CLI socket response surfaces a real error instead of silent ok=true.
      state.alert = AlertState {
        TextState("Working directory missing")
      } actions: {
        ButtonState(role: .cancel, action: .dismiss) {
          TextState("OK")
        }
      } message: {
        TextState(
          "\(worktree.name) has no working directory on disk. Restore it or delete the worktree."
        )
      }
      return .none
    }
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
        responseFD: responseFD,
        timeoutSeconds: timeoutSeconds
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
        responseFD: responseFD,
        timeoutSeconds: timeoutSeconds
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
      // Reject explicit IDs that collide with an existing or in-flight tab, so a
      // duplicate id can't have one creation resolve the other's ack.
      if let id,
        terminalClient.tabExists(worktreeID, TerminalTabID(rawValue: id))
          || Self.hasPendingCreationAck(id: id, state: state)
      {
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
        let effect = sendTerminalCommand(worktreeID: worktreeID, state: state) { worktree in
          .createTab(worktree, runSetupScriptIfNew: true, id: id)
        }
        return awaitingCompletion(
          effect, match: id.map { .tabInWorktree(worktreeID: worktreeID, tabID: $0) },
          responseFD: responseFD, timeoutSeconds: timeoutSeconds, state: &state)
      }
      if requiresInputConfirmation(state: state, bypassConfirmation: bypassConfirmation) {
        return presentDeeplinkConfirmation(
          worktreeID: worktreeID, responseFD: responseFD, timeoutSeconds: timeoutSeconds,
          message: .command(input), action: action, state: &state)
      }
      let effect = sendTerminalCommand(worktreeID: worktreeID, state: state) { worktree in
        .createTabWithInput(worktree, input: input, runSetupScriptIfNew: false, id: id)
      }
      return awaitingCompletion(
        effect, match: id.map { .tabInWorktree(worktreeID: worktreeID, tabID: $0) },
        responseFD: responseFD, timeoutSeconds: timeoutSeconds, state: &state)
    case .tabDestroy(let tabID):
      guard validateTab(worktreeID: worktreeID, tabID: tabID, state: &state) else { return .none }
      guard bypassConfirmation else {
        return presentDeeplinkConfirmation(
          worktreeID: worktreeID,
          responseFD: responseFD,
          timeoutSeconds: timeoutSeconds,
          message: .confirmation("Close tab \(tabID.uuidString.prefix(8))…?"),
          action: action,
          state: &state)
      }
      let effect = sendTerminalCommand(worktreeID: worktreeID, state: state) { worktree in
        .destroyTab(worktree, tabID: TerminalTabID(rawValue: tabID))
      }
      return awaitingCompletion(
        effect, match: .tabRemoved(worktreeID: worktreeID, tabID: TerminalTabID(rawValue: tabID)),
        responseFD: responseFD, timeoutSeconds: timeoutSeconds, state: &state)
    case .surface(let tabID, let surfaceID, let input):
      guard validateSurface(worktreeID: worktreeID, tabID: tabID, surfaceID: surfaceID, state: &state) else {
        return .none
      }
      if let input, !input.isEmpty,
        requiresInputConfirmation(state: state, bypassConfirmation: bypassConfirmation)
      {
        return presentDeeplinkConfirmation(
          worktreeID: worktreeID, responseFD: responseFD, timeoutSeconds: timeoutSeconds,
          message: .command(input), action: action, state: &state)
      }
      // Focus has no reliable completion signal (the event only fires when
      // focus actually moves), so this acks immediately.
      return sendTerminalCommand(worktreeID: worktreeID, state: state) { worktree in
        .focusSurface(worktree, tabID: TerminalTabID(rawValue: tabID), surfaceID: surfaceID, input: input)
      }
    case .surfaceSplit(let tabID, let surfaceID, let direction, let input, let id):
      guard validateSurface(worktreeID: worktreeID, tabID: tabID, surfaceID: surfaceID, state: &state) else {
        return .none
      }
      // Reject explicit IDs that collide with an existing or in-flight surface, so
      // a duplicate id can't have one split resolve the other's ack.
      if let id,
        terminalClient.surfaceExistsInWorktree(worktreeID, id)
          || Self.hasPendingCreationAck(id: id, state: state)
      {
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
          worktreeID: worktreeID, responseFD: responseFD, timeoutSeconds: timeoutSeconds,
          message: .command(input), action: action, state: &state)
      }
      let effect = sendTerminalCommand(worktreeID: worktreeID, state: state) { worktree in
        .splitSurface(
          worktree, tabID: TerminalTabID(rawValue: tabID), surfaceID: surfaceID,
          direction: direction, input: input, id: id)
      }
      return awaitingCompletion(
        effect, match: id.map { .surfaceSplit(worktreeID: worktreeID, surfaceID: $0) },
        responseFD: responseFD, timeoutSeconds: timeoutSeconds, state: &state)
    case .surfaceDestroy(let tabID, let surfaceID):
      guard validateSurface(worktreeID: worktreeID, tabID: tabID, surfaceID: surfaceID, state: &state) else {
        return .none
      }
      guard bypassConfirmation else {
        return presentDeeplinkConfirmation(
          worktreeID: worktreeID,
          responseFD: responseFD,
          timeoutSeconds: timeoutSeconds,
          message: .confirmation("Close surface \(surfaceID.uuidString.prefix(8))…?"),
          action: action,
          state: &state)
      }
      let effect = sendTerminalCommand(worktreeID: worktreeID, state: state) { worktree in
        .destroySurface(worktree, tabID: TerminalTabID(rawValue: tabID), surfaceID: surfaceID)
      }
      return awaitingCompletion(
        effect, match: .surfaceClosed(worktreeID: worktreeID, surfaceID: surfaceID),
        responseFD: responseFD, timeoutSeconds: timeoutSeconds, state: &state)
    }
  }

  private func runScriptDeeplinkEffect(
    worktreeID: Worktree.ID,
    scriptID: UUID,
    state: inout State,
    bypassConfirmation: Bool,
    responseFD: Int32?,
    timeoutSeconds: Int = defaultCommandTimeoutSeconds
  ) -> Effect<Action> {
    // Read scripts from storage so cross-worktree deeplinks are selection-agnostic.
    guard let worktree = state.repositories.worktree(for: worktreeID) else {
      state.alert = worktreeNotFoundAlert()
      return .none
    }
    guard let definition = resolveScript(scriptID: scriptID, in: worktree) else {
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
    guard state.repositories.sidebarItems[id: worktreeID]?.runningScripts[id: scriptID] == nil else {
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
        timeoutSeconds: timeoutSeconds,
        message: .command(definition.command),
        action: .runScript(scriptID: scriptID),
        state: &state
      )
    }
    analyticsClient.capture("script_run", ["kind": definition.kind.rawValue])
    let tint = definition.resolvedTintColor
    let terminalClient = terminalClient
    var effects: [Effect<Action>] = [
      .run { _ in
        await terminalClient.send(
          .runBlockingScript(worktree, kind: .script(definition), script: definition.command)
        )
      }
    ]
    if state.repositories.sidebarItems[id: worktreeID] != nil {
      effects.append(
        .send(
          .repositories(
            .sidebarItems(
              .element(id: worktreeID, action: .runningScriptStarted(id: scriptID, tint: tint))
            )
          )
        )
      )
    }
    return .merge(effects)
  }

  private func stopScriptDeeplinkEffect(
    worktreeID: Worktree.ID,
    scriptID: UUID,
    state: inout State
  ) -> Effect<Action> {
    // Read scripts from storage so cross-worktree deeplinks are selection-agnostic.
    guard let worktree = state.repositories.worktree(for: worktreeID) else {
      state.alert = worktreeNotFoundAlert()
      return .none
    }
    guard let definition = resolveScript(scriptID: scriptID, in: worktree) else {
      state.alert = scriptAlert(
        title: "Script not found",
        message: "No script matching the deeplink could be found. It may have been removed."
      )
      return .none
    }
    let runningScripts = state.repositories.sidebarItems[id: worktreeID]?.runningScripts ?? []
    guard runningScripts[id: scriptID] != nil else {
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

  private func pruneScriptRecencyEffect(state: State) -> Effect<Action> {
    let ids = CommandPaletteFeature.recencyRetentionIDs(
      from: state.repositories.repositories,
      scripts: state.allScripts
    )
    return .send(.commandPalette(.pruneRecency(ids)))
  }

  /// Resolves a script by ID across the worktree's repo scripts and the user's globals.
  /// Repo entries win when both buckets carry the same ID.
  private func resolveScript(scriptID: UUID, in worktree: Worktree) -> ScriptDefinition? {
    @SharedReader(.repositorySettings(worktree.repositoryRootURL, host: worktree.host)) var repositorySettings
    @SharedReader(.settingsFile) var settingsFile
    let merged: [ScriptDefinition] = .merged(
      repo: repositorySettings.scripts,
      global: settingsFile.global.globalScripts,
    )
    return merged.first(where: { $0.id == scriptID })
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

  private func repositoryNotFoundAlert() -> AlertState<Alert> {
    AlertState {
      TextState("Repository not found")
    } actions: {
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("OK")
      }
    } message: {
      TextState("No repository matching the deeplink could be found.")
    }
  }

  private func deeplinkDeleteWorktreeEffect(
    worktreeID: Worktree.ID,
    action: Deeplink.WorktreeAction,
    state: inout State,
    bypassConfirmation: Bool,
    responseFD: Int32? = nil,
    timeoutSeconds: Int = defaultCommandTimeoutSeconds
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
      // A folder already removing / not idle, or one whose shared alert slot is
      // occupied (a second confirmation would displace the first, stranding its
      // ack), has no usable completion signal, so reject it now.
      let folderEligible =
        state.repositories.removingRepositoryIDs[repositoryID] == nil
        && state.repositories.alert == nil
        && (state.repositories.sidebarItems[id: worktreeID]?.lifecycle ?? .idle) == .idle
      guard folderEligible else {
        let folderName = state.repositories.repositories[id: repositoryID]?.name ?? "This folder"
        state.alert = AlertState {
          TextState("Delete unavailable")
        } actions: {
          ButtonState(role: .cancel, action: .dismiss) { TextState("OK") }
        } message: {
          TextState("\(folderName) can't be deleted right now (another operation is in progress).")
        }
        return .none
      }
      // Folders always surface the 3-button confirmation so users
      // can pick between `.folderUnlink` (drop from sidebar, stay
      // on disk) and `.folderTrash` (move to Trash). The deeplink
      // `bypassConfirmation` flag still shows it — there's no
      // reasonable default disposition for folders. Hold the ack until
      // the removal completes (or the user cancels) instead of acking
      // success while the confirmation is still on screen.
      return awaitingCompletion(
        .send(.repositories(.requestDeleteSidebarItems([target]))),
        match: .folderRemoved(repositoryID: repositoryID),
        responseFD: responseFD, timeoutSeconds: timeoutSeconds, state: &state)
    }
    let worktreeName = state.repositories.worktree(for: worktreeID)?.name ?? worktreeID.rawValue
    // A worktree already winding down hits deleteSidebarItemConfirmed's re-entry
    // guard, which no-ops with no completion event, so an ack could only time out.
    let lifecycle = state.repositories.sidebarItems[id: worktreeID]?.lifecycle ?? .idle
    guard !lifecycle.isTerminating else {
      state.alert = AlertState {
        TextState("Delete unavailable")
      } actions: {
        ButtonState(role: .cancel, action: .dismiss) { TextState("OK") }
      } message: {
        TextState("\"\(worktreeName)\" can't be deleted right now (another operation is in progress).")
      }
      return .none
    }
    guard bypassConfirmation else {
      return presentDeeplinkConfirmation(
        worktreeID: worktreeID,
        responseFD: responseFD,
        timeoutSeconds: timeoutSeconds,
        message: .confirmation("Delete worktree \"\(worktreeName)\"?"),
        action: action,
        state: &state
      )
    }
    return awaitingCompletion(
      .send(.repositories(.deleteSidebarItemConfirmed(worktreeID, repositoryID))),
      match: .worktreeRemoved(worktreeID: worktreeID),
      responseFD: responseFD, timeoutSeconds: timeoutSeconds, state: &state)
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

  /// True when in-flight work would not survive a quit. Steady-state
  /// `.idle` agents are intentionally excluded since persisting them is the
  /// whole reason zmx wraps the shell; only mid-tool-call (`.busy`) and
  /// prompt-waiting (`.awaitingInput`) agents are at risk. Running user
  /// scripts also block because their stdout history dies with the shell.
  private func hasActiveWorkBlockingQuit(state: State) -> Bool {
    if terminalClient.hasInflightBlockingScripts() { return true }
    return state.repositories.sidebarItems.contains { item in
      if item.lifecycle.isTerminating || item.lifecycle == .pending { return true }
      if !item.runningScripts.isEmpty { return true }
      return item.agents.contains { $0.activity != .idle }
    }
  }

  /// Single source of truth for the `(terminateOnQuit, hasBlockingScripts)`
  /// matrix that drives the quit alert. Nested for namespacing (single-use).
  struct QuitConfirmationContext: Equatable {
    let terminateOnQuit: Bool
    let hasBlockingScripts: Bool

    var primaryLabel: String {
      switch (terminateOnQuit, hasBlockingScripts) {
      case (false, false): "Quit"
      case (false, true): "Quit and Stop Scripts"
      case (true, false): "Quit and Terminate Sessions"
      case (true, true): "Quit and Stop Everything"
      }
    }

    /// `nil` when the user opted into terminate-on-quit globally; the primary
    /// button already runs the destructive path so a duplicate would be noise.
    var destructiveLabel: String? {
      guard !terminateOnQuit else { return nil }
      return hasBlockingScripts ? "Quit and Stop Everything" : "Quit and Terminate Sessions"
    }

    var message: String {
      switch (terminateOnQuit, hasBlockingScripts) {
      case (false, false):
        return "Terminal sessions keep running in the background after you quit. "
          + "Choose Quit and Terminate Sessions to also close every tab and stop their shells."
      case (false, true):
        return "Running scripts will be stopped and lost. Terminal sessions keep running in the background. "
          + "Choose Quit and Stop Everything to also close every tab and stop their shells."
      case (true, false):
        return "All terminal tabs will be closed and background shells stopped."
      case (true, true):
        return "Running scripts will be stopped and lost. "
          + "All terminal tabs will be closed and background shells stopped."
      }
    }
  }

  /// Builds the quit confirmation. Cancel is the default so a user mashing
  /// Enter never accidentally quits. Labels + message route through
  /// `QuitConfirmationContext` so adding a future axis (e.g. mid-archive)
  /// only edits one matrix instead of three dispatch points.
  private func quitConfirmationAlert(
    terminateOnQuit: Bool,
    hasBlockingScripts: Bool
  ) -> AlertState<Alert> {
    let context = QuitConfirmationContext(
      terminateOnQuit: terminateOnQuit,
      hasBlockingScripts: hasBlockingScripts
    )
    return AlertState {
      TextState("Quit Supacode?")
    } actions: {
      ButtonState(role: .cancel, action: .dismiss) { TextState("Cancel") }
      ButtonState(action: .confirmQuit) { TextState(context.primaryLabel) }
      if let destructive = context.destructiveLabel {
        ButtonState(role: .destructive, action: .confirmQuitAndTerminate) { TextState(destructive) }
      }
    } message: {
      TextState(context.message)
    }
  }

  /// Performs the actual quit. When `terminateSessions` is true we await
  /// `terminateAllSessions` before calling `appLifecycleClient.terminate()`
  /// so the zmx daemon teardown completes inside the process lifetime.
  private func quitEffect(state: inout State, terminateSessions: Bool) -> Effect<Action> {
    analyticsClient.capture("app_quit", ["terminate_sessions": terminateSessions])
    let pendingFDEffect = drainPendingResponseFD(state: &state, error: "Supacode is quitting.")
    let pendingAcksEffect = drainAllCommandAcks(state: &state, error: "Supacode is quitting.")
    let terminateEffect: Effect<Action> = .run { @MainActor [terminalClient, appLifecycleClient] _ in
      if terminateSessions {
        await terminalClient.terminateAllSessions()
      }
      appLifecycleClient.terminate()
    }
    return .concatenate(pendingFDEffect, pendingAcksEffect, terminateEffect)
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
    error: String? = nil,
    resourceID: String? = nil
  ) -> Effect<Action> {
    .run { _ in
      AgentHookSocketServer.sendCommandResponse(
        clientFD: clientFD, ok: succeeded, error: error, resourceID: resourceID)
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

  // MARK: Deferred completion acks.

  /// Prefix for the synthetic worktree id that correlates a CLI worktree-new ack
  /// to its creation. Never collides with a real worktree id (a filesystem path).
  private static let cliPendingWorktreePrefix = "pending:cli-"

  /// Parses the `timeout` query item (seconds) the CLI embeds in command
  /// deeplinks. Falls back to the default; clamps negatives to 0 (indefinite).
  private static func parseTimeoutSeconds(from url: URL) -> Int {
    guard
      let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "timeout" })?.value,
      let seconds = Int(raw)
    else {
      return defaultCommandTimeoutSeconds
    }
    return max(seconds, 0)
  }

  /// Percent-encodes a resource id the same way the socket query handlers do,
  /// so a returned id round-trips as a `-w` / `-r` argument.
  private static func percentEncodedID(_ rawValue: String) -> String {
    let allowed = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "/"))
    return rawValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? rawValue
  }

  /// True when a creation ack (tab new / surface split) is already pending for
  /// `id`, so a duplicate explicit id can't have one creation resolve the other.
  private static func hasPendingCreationAck(id: UUID?, state: State) -> Bool {
    guard let id else { return false }
    return state.pendingCommandAcks.contains { ack in
      switch ack.match {
      case .tabInWorktree(_, let tabID): return tabID == id
      case .surfaceSplit(_, let surfaceID): return surfaceID == id
      default: return false
      }
    }
  }

  /// Registers a deferred completion ack and merges in its watchdog. A `nil`
  /// `match` (e.g. tab-new without a correlatable id) or `nil` `responseFD`
  /// (no socket caller) leaves the ack immediate, returning `effect` unchanged.
  private func awaitingCompletion(
    _ effect: Effect<Action>,
    match: CompletionMatch?,
    responseFD: Int32?,
    timeoutSeconds: Int,
    state: inout State
  ) -> Effect<Action> {
    guard let responseFD, let match else { return effect }
    // One open fd carries one command, so a pending ack here is unexpected.
    // Cancel its watchdog before overwriting so no stale timer lingers.
    var supersede: Effect<Action> = .none
    if let stale = state.pendingCommandAcks[id: responseFD] {
      appLogger.warning("Superseding an unresolved command ack on fd \(responseFD).")
      supersede = .cancel(id: CancelID.commandAck(responseFD, stale.token))
    }
    state.commandAckGeneration += 1
    let token = state.commandAckGeneration
    state.pendingCommandAcks[id: responseFD] = PendingCommandAck(
      responseFD: responseFD, token: token, match: match)
    return .merge(
      supersede,
      effect,
      makeAckTimeoutEffect(responseFD: responseFD, token: token, timeoutSeconds: timeoutSeconds))
  }

  /// Watchdog draining a pending ack with a timeout error if its completion
  /// signal never arrives. `timeoutSeconds <= 0` waits indefinitely.
  private func makeAckTimeoutEffect(
    responseFD: Int32, token: Int, timeoutSeconds: Int
  ) -> Effect<Action> {
    guard timeoutSeconds > 0 else { return .none }
    return .run { [clock] send in
      try await clock.sleep(for: .seconds(timeoutSeconds))
      await send(.commandAckTimedOut(responseFD: responseFD, token: token))
    }
    .cancellable(id: CancelID.commandAck(responseFD, token), cancelInFlight: true)
  }

  /// Drains every pending ack whose match satisfies `predicate`, sending each a
  /// response and cancelling its watchdog. `resourceID` is echoed to the CLI so
  /// a creation command can print the created resource.
  private func resolveCommandAcks(
    ok succeeded: Bool,
    error: String? = nil,
    resourceID: String? = nil,
    state: inout State,
    where predicate: (CompletionMatch) -> Bool
  ) -> Effect<Action> {
    let matched = state.pendingCommandAcks.filter { predicate($0.match) }
    guard !matched.isEmpty else { return .none }
    for ack in matched { state.pendingCommandAcks.remove(id: ack.id) }
    return .merge(matched.map { drainAck($0, ok: succeeded, error: error, resourceID: resourceID) })
  }

  /// Sends a response on a pending ack's fd and cancels its watchdog.
  private func drainAck(
    _ ack: PendingCommandAck, ok succeeded: Bool, error: String?, resourceID: String? = nil
  ) -> Effect<Action> {
    .merge(
      sendSocketResponse(
        clientFD: ack.responseFD, ok: succeeded, error: error, resourceID: resourceID),
      .cancel(id: CancelID.commandAck(ack.responseFD, ack.token))
    )
  }

  /// Binds a pending worktree-new ack (registered with its pending id before the
  /// real worktree id was known) to the created worktree id, so its first tab
  /// resolves it.
  private func bindWorktreeNewAck(
    pendingID: Worktree.ID, to worktreeID: Worktree.ID, state: inout State
  ) {
    guard
      let responseFD = state.pendingCommandAcks.first(where: { ack in
        if case .worktreeNew(let ackPendingID, nil) = ack.match { return ackPendingID == pendingID }
        return false
      })?.responseFD
    else { return }
    state.pendingCommandAcks[id: responseFD]?.match = .worktreeNew(
      pendingID: pendingID, worktreeID: worktreeID)
  }

  /// Drains all pending acks (used on quit) so no client fd leaks.
  private func drainAllCommandAcks(state: inout State, error: String) -> Effect<Action> {
    let acks = state.pendingCommandAcks
    guard !acks.isEmpty else { return .none }
    state.pendingCommandAcks.removeAll()
    return .merge(acks.map { drainAck($0, ok: false, error: error) })
  }

  private func presentDeeplinkConfirmation(
    worktreeID: Worktree.ID,
    responseFD: Int32? = nil,
    timeoutSeconds: Int = defaultCommandTimeoutSeconds,
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
    state.confirmationGeneration += 1
    let token = state.confirmationGeneration
    state.deeplinkInputConfirmation = DeeplinkInputConfirmationFeature.State(
      worktreeID: worktreeID,
      worktreeName: worktreeName,
      repositoryName: repoName,
      message: message,
      action: action,
      responseFD: responseFD,
      timeoutSeconds: timeoutSeconds,
      timeoutToken: token
    )
    // A socket-backed dialog left open would strand its fd, so time it out on the
    // same budget. Always cancel the prior dialog's watchdog, even when this
    // replacement starts none, so a superseded watchdog can't outlive its dialog.
    let cancelPrior: Effect<Action> = .cancel(id: CancelID.deeplinkConfirmationTimeout)
    let watchdog: Effect<Action>
    if let responseFD, timeoutSeconds > 0 {
      watchdog = .run { [clock] send in
        try await clock.sleep(for: .seconds(timeoutSeconds))
        await send(.deeplinkConfirmationTimedOut(responseFD: responseFD, token: token))
      }
      .cancellable(id: CancelID.deeplinkConfirmationTimeout, cancelInFlight: true)
    } else {
      watchdog = .none
    }
    return .merge(cancelPrior, supersededEffect, watchdog)
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
    let alternate = WorktreeID(rawID.rawValue + "/")
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
      case .developer: .developer
      case .shortcuts: .shortcuts
      case .scripts: .scripts
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
      worktreeID.rawValue.addingPercentEncoding(withAllowedCharacters: percentEncodingSet) ?? worktreeID.rawValue
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
