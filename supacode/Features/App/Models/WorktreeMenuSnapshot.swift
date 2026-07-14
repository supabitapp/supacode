import Foundation
import SupacodeSettingsFeature
import SupacodeSettingsShared

#if DEBUG
  private nonisolated let menuSnapshotLogger = SupaLogger("DetailRender")
#endif

/// Frozen view of every primitive the `WorktreeCommands` menu-bar body reads.
/// `WorktreeCommands.body` observes only this single Equatable field; mutations
/// fire only when a value the menu actually displays changes.
struct WorktreeMenuSnapshot: Equatable {
  var shortcutOverrides: [AppShortcutID: AppShortcutOverride] = [:]
  var githubIntegrationEnabled: Bool = true
  var canCreateWorktree: Bool = false
  var canNavigateBackward: Bool = false
  var canNavigateForward: Bool = false
  var isInitialLoadComplete: Bool = false
  var selectedPullRequestURL: URL?
  var notificationIndicatorCount: Int = 0
}

extension AppFeature.State {
  /// Compose the current snapshot from substate fields. Called from the
  /// post-reduce hook on the root reducer; Equatable diff suppresses no-op
  /// writes so SwiftUI only invalidates when something the menu reads changed.
  func computeWorktreeMenuSnapshot() -> WorktreeMenuSnapshot {
    let pullRequestURL = repositories.selectedWorktreeSlice?.pullRequest
      .flatMap { URL(string: $0.url) }
    return WorktreeMenuSnapshot(
      shortcutOverrides: settings.shortcutOverrides,
      githubIntegrationEnabled: settings.githubIntegrationEnabled,
      canCreateWorktree: repositories.canCreateWorktree,
      canNavigateBackward: repositories.canNavigateWorktreeHistoryBackward,
      canNavigateForward: repositories.canNavigateWorktreeHistoryForward,
      isInitialLoadComplete: repositories.isInitialLoadComplete,
      selectedPullRequestURL: pullRequestURL,
      notificationIndicatorCount: notificationIndicatorCount
    )
  }

  mutating func recomputeWorktreeMenuSnapshotIfChanged() {
    let new = computeWorktreeMenuSnapshot()
    if new != worktreeMenuSnapshot {
      #if DEBUG
        diffSnapshotFields(old: worktreeMenuSnapshot, new: new)
      #endif
      worktreeMenuSnapshot = new
    }
  }

  #if DEBUG
    private func diffSnapshotFields(old: WorktreeMenuSnapshot, new: WorktreeMenuSnapshot) {
      var diffs: [String] = []
      if old.shortcutOverrides != new.shortcutOverrides { diffs.append("shortcutOverrides") }
      if old.githubIntegrationEnabled != new.githubIntegrationEnabled {
        diffs.append("githubIntegrationEnabled")
      }
      if old.canCreateWorktree != new.canCreateWorktree { diffs.append("canCreateWorktree") }
      if old.canNavigateBackward != new.canNavigateBackward {
        diffs.append("canNavigateBackward")
      }
      if old.canNavigateForward != new.canNavigateForward {
        diffs.append("canNavigateForward")
      }
      if old.isInitialLoadComplete != new.isInitialLoadComplete {
        diffs.append("isInitialLoadComplete")
      }
      if old.selectedPullRequestURL != new.selectedPullRequestURL {
        diffs.append("selectedPullRequestURL")
      }
      if old.notificationIndicatorCount != new.notificationIndicatorCount {
        diffs.append("notificationIndicatorCount")
      }
      menuSnapshotLogger.info("MenuSnapshot mutated. Fields: \(diffs.joined(separator: ", "))")
    }
  #endif
}

extension AppFeature.Action {
  /// Exhaustive gate for the `WorktreeMenuSnapshot` post-reduce recompute.
  /// A `default` arm would silently classify any new action as "no recompute"
  /// and risk a stale snapshot; the explicit switch forces classification at
  /// compile time. The Equatable diff inside
  /// `recomputeWorktreeMenuSnapshotIfChanged` still catches no-op recomputes;
  /// this gate avoids the recompute itself on the action volumes #289 cares
  /// about (agent-presence ticks, per-tab projection storms).
  var affectsWorktreeMenuSnapshot: Bool {
    switch self {
    // Repository actions: the existing cache-invalidation map is the source
    // of truth. Every snapshot input that lives on `repositories` (canCreate,
    // canNavigate*, isInitialLoadComplete, selectedWorktreeSlice.pullRequest)
    // changes via an action that already invalidates at least one cache.
    case .repositories(let inner):
      return !inner.cacheInvalidations.isEmpty
    // Settings can change `shortcutOverrides` or `githubIntegrationEnabled`.
    case .settings:
      return true
    // Only `notificationIndicatorChanged` writes the snapshot's count field.
    case .terminalEvent(let event):
      switch event {
      case .notificationIndicatorChanged:
        return true
      case .notificationReceived, .tabCreated, .tabClosed, .focusChanged,
        .taskStatusChanged, .blockingScriptCompleted, .commandPaletteToggleRequested,
        .setupScriptConsumed, .worktreeProjectionChanged, .tabProjectionChanged,
        .tabRemoved, .tabRenamed, .worktreeStateTornDown, .tabProgressDisplayChanged,
        .surfacesClosed, .agentHookEventReceived, .terminalHasAnySurfaceChanged,
        .surfaceCreationFailed:
        return false
      }
    // Hot agent-storm paths: per-tab churn never mutates snapshot inputs.
    // `.terminals` is safe because it owns only per-tab feature state; any
    // change that DOES affect a snapshot input flows back through a separate
    // `.terminalEvent.notificationIndicatorChanged` (counted above) or a
    // `.repositories` cache invalidation (the cacheInvalidations gate above).
    case .agentPresence, .terminals, .commandPalette, .updates:
      return false
    // Lifecycle / UI / effect-dispatch actions never write snapshot inputs
    // directly; any downstream mutation flows back through a classified arm.
    case .applicationDidBecomeActive, .applicationDidResignActive,
      .appLaunched, .scenePhaseChanged, .openActionSelectionChanged,
      .worktreeSettingsLoaded, .openSelectedWorktree, .revealInFinder,
      .openWorktree, .openWorktreeFailed, .requestQuit,
      .requestTerminateAllTerminalSessions, .newTerminal,
      .selectTerminalTabAtIndex, .splitTerminal, .jumpToLatestUnread, .runScript, .runNamedScript,
      .stopScript, .stopRunScripts, .closeTab, .closeSurface,
      .startSearch, .searchSelection, .navigateSearchNext,
      .navigateSearchPrevious, .endSearch,
      .systemNotificationsPermissionFailed, .deeplinkReceived,
      .deeplink, .commandAckTimedOut, .deeplinkConfirmationTimedOut,
      .deeplinkReferenceOpened, .alert, .deeplinkInputConfirmation:
      return false
    }
  }
}
