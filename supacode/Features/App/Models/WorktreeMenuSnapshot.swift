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
