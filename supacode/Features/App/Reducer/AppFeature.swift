import AppKit
import ComposableArchitecture
import Foundation
import PostHog
import Sentry
import SwiftUI

private let notificationSound: NSSound? = {
  guard let url = Bundle.main.url(forResource: "notification", withExtension: "wav") else {
    return nil
  }
  return NSSound(contentsOf: url, byReference: true)
}()

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
    var selectedRunScript: String = ""
    var runScriptDraft: String = ""
    var isRunScriptPromptPresented = false
    var runScriptStatusByWorktreeID: [Worktree.ID: Bool] = [:]
    var notificationIndicatorCount: Int = 0
    @Presents var alert: AlertState<Alert>?
    var commandPaletteItems: [CommandPaletteItem] {
      CommandPaletteFeature.commandPaletteItems(from: repositories)
    }

    init(
      repositories: RepositoriesFeature.State = .init(),
      settings: SettingsFeature.State = .init()
    ) {
      self.repositories = repositories
      self.settings = settings
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
    case openWorktree(OpenWorktreeAction)
    case openWorktreeFailed(OpenActionError)
    case requestQuit
    case newTerminal
    case runScript
    case runScriptDraftChanged(String)
    case runScriptPromptPresented(Bool)
    case saveRunScriptAndRun
    case stopRunScript
    case closeTab
    case closeSurface
    case startSearch
    case searchSelection
    case navigateSearchNext
    case navigateSearchPrevious
    case endSearch
    case alert(PresentationAction<Alert>)
    case terminalEvent(TerminalClient.Event)
  }

  enum Alert: Equatable {
    case dismiss
    case confirmQuit
  }

  @Dependency(\.analyticsClient) private var analyticsClient
  @Dependency(\.repositoryPersistence) private var repositoryPersistence
  @Dependency(\.workspaceClient) private var workspaceClient
  @Dependency(\.settingsWindowClient) private var settingsWindowClient
  @Dependency(\.terminalClient) private var terminalClient
  @Dependency(\.worktreeInfoWatcher) private var worktreeInfoWatcher

  var body: some Reducer<State, Action> {
    let core = Reduce<State, Action> { state, action in
      switch action {
      case .appLaunched:
        return .merge(
          .send(.repositories(.task)),
          .send(.settings(.task)),
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
                try? await Task.sleep(for: .seconds(30))
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
        let repositoryPersistence = repositoryPersistence
        let worktreesForWatcher = state.repositories.worktreesForInfoWatcher()
        guard let worktree else {
          state.openActionSelection = .finder
          state.selectedRunScript = ""
          state.runScriptDraft = ""
          state.isRunScriptPromptPresented = false
          var effects: [Effect<Action>] = [
            .run { _ in
              await terminalClient.send(.setSelectedWorktreeID(nil))
            },
            .run { _ in
              await worktreeInfoWatcher.send(.setSelectedWorktreeID(nil))
            },
            .run { _ in
              await worktreeInfoWatcher.send(.setWorktrees(worktreesForWatcher))
            },
          ]
          if !state.repositories.isShowingArchivedWorktrees {
            effects.insert(
              .run { _ in
                await repositoryPersistence.saveLastFocusedWorktreeID(lastFocusedWorktreeID)
              },
              at: 0
            )
          }
          return .merge(effects)
        }
        let rootURL = worktree.repositoryRootURL
        let worktreeID = worktree.id
        state.runScriptDraft = ""
        state.isRunScriptPromptPresented = false
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        let settings = repositorySettings
        return .merge(
          .run { _ in
            await repositoryPersistence.saveLastFocusedWorktreeID(lastFocusedWorktreeID)
          },
          .run { _ in
            await terminalClient.send(.setSelectedWorktreeID(worktree.id))
          },
          .run { _ in
            await worktreeInfoWatcher.send(.setSelectedWorktreeID(worktree.id))
          },
          .run { _ in
            await worktreeInfoWatcher.send(.setWorktrees(worktreesForWatcher))
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
        let ids = Set(repositories.flatMap { $0.worktrees.map(\.id) })
        let recencyIDs = CommandPaletteFeature.recencyRetentionIDs(from: repositories)
        let worktrees = state.repositories.worktreesForInfoWatcher()
        state.runScriptStatusByWorktreeID = state.runScriptStatusByWorktreeID.filter { ids.contains($0.key) }
        if case .repository(let repositoryID)? = state.settings.selection,
          !repositories.contains(where: { $0.id == repositoryID })
        {
          return .merge(
            .send(.settings(.setSelection(.general))),
            .send(.commandPalette(.pruneRecency(recencyIDs))),
            .run { _ in
              await terminalClient.send(.prune(ids))
            },
            .run { _ in
              await worktreeInfoWatcher.send(.setWorktrees(worktrees))
            }
          )
        }
        return .merge(
          .send(.commandPalette(.pruneRecency(recencyIDs))),
          .run { _ in
            await terminalClient.send(.prune(ids))
          },
          .run { _ in
            await worktreeInfoWatcher.send(.setWorktrees(worktrees))
          }
        )

      case .repositories(.delegate(.openRepositorySettings(let repositoryID))):
        guard state.repositories.repositories.contains(where: { $0.id == repositoryID }) else {
          return .none
        }
        let selection = SettingsSection.repository(repositoryID)
        return .merge(
          .send(.settings(.setSelection(selection))),
          .run { _ in
            await settingsWindowClient.show()
          }
        )

      case .settings(.setSelection(let selection)):
        let resolvedSelection = selection ?? .general
        switch resolvedSelection {
        case .repository(let repositoryID):
          guard let repository = state.repositories.repositories[id: repositoryID] else {
            state.settings.repositorySettings = nil
            return .none
          }
          @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
          state.settings.repositorySettings = RepositorySettingsFeature.State(
            rootURL: repository.rootURL,
            settings: repositorySettings
          )
        case .general, .notifications, .worktree, .updates, .advanced, .github:
          state.settings.repositorySettings = nil
        }
        return .none

      case .repositories(.worktreePullRequestLoaded):
        return .none

      case .settings(.delegate(.settingsChanged(let settings))):
        let badgeLabel =
          settings.dockBadgeEnabled
          ? (state.notificationIndicatorCount == 0 ? nil : String(state.notificationIndicatorCount))
          : nil
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
              .setAutomaticallyArchiveMergedWorktrees(
                settings.automaticallyArchiveMergedWorktrees
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
            await MainActor.run {
              NSApplication.shared.dockTile.badgeLabel = badgeLabel
            }
          },
          .run { _ in
            await worktreeInfoWatcher.send(
              .setPullRequestTrackingEnabled(settings.githubIntegrationEnabled)
            )
          }
        )

      case .openActionSelectionChanged(let action):
        state.openActionSelection = action
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          return .none
        }
        let rootURL = worktree.repositoryRootURL
        let actionID = action.settingsID
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        $repositorySettings.withLock { $0.openActionID = actionID }
        return .none

      case .openSelectedWorktree:
        return .send(.openWorktree(OpenWorktreeAction.availableSelection(state.openActionSelection)))

      case .openWorktree(let action):
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          return .none
        }
        analyticsClient.capture("worktree_opened", ["action": action.settingsID])
        if action == .editor {
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
        return .run { send in
          await workspaceClient.open(action, worktree) { error in
            send(.openWorktreeFailed(error))
          }
        }

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
        #if !DEBUG
          guard state.settings.confirmBeforeQuit else {
            analyticsClient.capture("app_quit", nil)
            return .run { @MainActor _ in
              NSApplication.shared.terminate(nil)
            }
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
          return .none
        #else
          return .run { @MainActor _ in
            NSApplication.shared.terminate(nil)
          }
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

      case .runScript:
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          return .none
        }
        let trimmed = state.selectedRunScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          if state.isRunScriptPromptPresented {
            return .none
          }
          state.runScriptDraft = state.selectedRunScript
          state.isRunScriptPromptPresented = true
          return .none
        }
        analyticsClient.capture("script_run", nil)
        let script = state.selectedRunScript
        return .run { _ in
          await terminalClient.send(.runScript(worktree, script: script))
        }

      case .runScriptDraftChanged(let script):
        state.runScriptDraft = script
        return .none

      case .runScriptPromptPresented(let isPresented):
        state.isRunScriptPromptPresented = isPresented
        if !isPresented {
          state.runScriptDraft = ""
        }
        return .none

      case .saveRunScriptAndRun:
        guard let worktree = state.repositories.worktree(for: state.repositories.selectedWorktreeID) else {
          state.isRunScriptPromptPresented = false
          state.runScriptDraft = ""
          return .none
        }
        let script = state.runScriptDraft
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          return .none
        }
        let rootURL = worktree.repositoryRootURL
        @Shared(.repositorySettings(rootURL)) var repositorySettings
        $repositorySettings.withLock { $0.runScript = script }
        if state.settings.repositorySettings?.rootURL == rootURL {
          state.settings.repositorySettings?.settings.runScript = script
        }
        state.selectedRunScript = script
        state.isRunScriptPromptPresented = false
        state.runScriptDraft = ""
        return .send(.runScript)

      case .stopRunScript:
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
        state.selectedRunScript = settings.runScript
        return .none

      case .alert(.dismiss):
        state.alert = nil
        return .none

      case .alert(.presented(.confirmQuit)):
        analyticsClient.capture("app_quit", nil)
        state.alert = nil
        return .run { @MainActor _ in
          NSApplication.shared.terminate(nil)
        }

      case .alert:
        return .none

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
        return .merge(
          .send(.settings(.setSelection(.general))),
          .run { _ in
            await settingsWindowClient.show()
          }
        )

      case .commandPalette(.delegate(.newWorktree)):
        return .send(.repositories(.createRandomWorktree))

      case .commandPalette(.delegate(.openRepository)):
        return .send(.repositories(.setOpenPanelPresented(true)))

      case .commandPalette(.delegate(.removeWorktree(let worktreeID, let repositoryID))):
        return .send(.repositories(.requestDeleteWorktree(worktreeID, repositoryID)))

      case .commandPalette(.delegate(.archiveWorktree(let worktreeID, let repositoryID))):
        return .send(.repositories(.requestArchiveWorktree(worktreeID, repositoryID)))

      case .commandPalette(.delegate(.refreshWorktrees)):
        return .send(.repositories(.refreshWorktrees))

      case .commandPalette(.delegate(.openPullRequest(let worktreeID))):
        return .send(.repositories(.pullRequestAction(worktreeID, .openOnGithub)))

      case .commandPalette(.delegate(.markPullRequestReady(let worktreeID))):
        return .send(.repositories(.pullRequestAction(worktreeID, .markReadyForReview)))

      case .commandPalette(.delegate(.mergePullRequest(let worktreeID))):
        return .send(.repositories(.pullRequestAction(worktreeID, .merge)))

      case .commandPalette(.delegate(.copyCiFailureLogs(let worktreeID))):
        return .send(.repositories(.pullRequestAction(worktreeID, .copyCiFailureLogs)))

      case .commandPalette(.delegate(.rerunFailedJobs(let worktreeID))):
        return .send(.repositories(.pullRequestAction(worktreeID, .rerunFailedJobs)))

      case .commandPalette(.delegate(.openFailingCheckDetails(let worktreeID))):
        return .send(.repositories(.pullRequestAction(worktreeID, .openFailingCheckDetails)))

      #if DEBUG
        case .commandPalette(.delegate(.debugTestToast(let toast))):
          return .send(.repositories(.showToast(toast)))
      #endif

      case .commandPalette:
        return .none

      case .terminalEvent(.notificationReceived(let worktreeID, _, _)):
        var effects: [Effect<Action>] = [
          .send(.repositories(.worktreeNotificationReceived(worktreeID)))
        ]
        if state.settings.notificationSoundEnabled {
          effects.append(
            .run { _ in
              await MainActor.run { _ = notificationSound?.play() }
            }
          )
        }
        return .merge(effects)

      case .terminalEvent(.notificationIndicatorChanged(let count)):
        state.notificationIndicatorCount = count
        let badgeLabel =
          state.settings.dockBadgeEnabled
          ? (count == 0 ? nil : String(count))
          : nil
        return .run { _ in
          await MainActor.run {
            NSApplication.shared.dockTile.badgeLabel = badgeLabel
          }
        }

      case .terminalEvent(.runScriptStatusChanged(let worktreeID, let isRunning)):
        if isRunning {
          state.runScriptStatusByWorktreeID[worktreeID] = true
        } else {
          state.runScriptStatusByWorktreeID.removeValue(forKey: worktreeID)
        }
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

      case .terminalEvent:
        return .none
      }
    }
    core
      .printActionLabels()
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
  }
}

private struct ActionLabelReducer<Base: Reducer>: Reducer {
  let base: Base

  func reduce(into state: inout Base.State, action: Base.Action) -> Effect<Base.Action> {
    let actionLabel = debugCaseOutput(action)
    #if !DEBUG
      SentrySDK.logger.info("received action: \(actionLabel)")
    #endif
    return base.reduce(into: &state, action: action)
  }
}

extension Reducer {
  fileprivate func printActionLabels() -> ActionLabelReducer<Self> {
    ActionLabelReducer(base: self)
  }
}
