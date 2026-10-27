import ComposableArchitecture
import Foundation
import OrderedCollections
import SupacodeSettingsShared

extension RepositoriesFeature {
  /// Where "Customize Appearance" lands for a sidebar selection. The command
  /// palette and the Worktrees menu shortcut both resolve through
  /// `State.customizeAppearanceRowTarget` / `customizeAppearanceRepositoryTarget`
  /// so there is one rule set for which selection customizes what.
  enum CustomizeAppearanceTarget: Equatable, Hashable, Sendable {
    /// The row's own bucket: a folder row, or a non-main git worktree.
    case worktree(Worktree.ID, Repository.ID)
    /// The repository section header (git repos only).
    case repository(Repository.ID)
  }
}

extension RepositoriesFeature.State {
  /// The selected row's own appearance target: a folder row (checked first,
  /// since a folder row is also its repository's root) or a non-main git
  /// worktree. `nil` for a git main worktree, which is repository-level, and
  /// for a pending row, which has no stable target yet (mirroring the
  /// sidebar's `!lifecycle.isPending` gate).
  var customizeAppearanceRowTarget: RepositoriesFeature.CustomizeAppearanceTarget? {
    guard let selectedWorktreeID,
      let selectedRow = sidebarItems[id: selectedWorktreeID],
      let repositoryID = self.repositoryID(containing: selectedWorktreeID)
    else {
      return nil
    }
    if selectedRow.isFolder {
      return .worktree(selectedWorktreeID, repositoryID)
    }
    guard !selectedRow.isMainWorktree, !selectedRow.lifecycle.isPending else { return nil }
    return .worktree(selectedWorktreeID, repositoryID)
  }

  /// The repository-level appearance target for the selection: git repos only
  /// (folder repos have no section header to tint), and hidden mid-removal to
  /// match the disabled sidebar entry.
  var customizeAppearanceRepositoryTarget: RepositoriesFeature.CustomizeAppearanceTarget? {
    guard let selectedWorktreeID,
      sidebarItems[id: selectedWorktreeID] != nil,
      let repositoryID = self.repositoryID(containing: selectedWorktreeID),
      repositories[id: repositoryID]?.isGitRepository == true,
      removingRepositoryIDs[repositoryID] == nil
    else {
      return nil
    }
    return .repository(repositoryID)
  }

  /// The single target the Customize Appearance shortcut opens: the row's own
  /// when it has one, else the repository's for a git main worktree. Pending
  /// rows, archived / failed selections, and no selection resolve to `nil`.
  var customizeAppearanceShortcutTarget: RepositoriesFeature.CustomizeAppearanceTarget? {
    if let rowTarget = customizeAppearanceRowTarget {
      return rowTarget
    }
    guard let selectedWorktreeID, sidebarItems[id: selectedWorktreeID]?.isMainWorktree == true else {
      return nil
    }
    return customizeAppearanceRepositoryTarget
  }
}

extension RepositoriesFeature {
  /// Dedicated reducer for the per-worktree customization flow. Lives in its own file so the main
  /// `body` switch stays under the Swift type-checker's complexity limit.
  static var worktreeCustomizationReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .requestCustomizeSelectedAppearance:
        // Resolved at fire time rather than baked into the menu item so a
        // selection that went pending or archived since the menu was built
        // is dropped here instead of opening a stale sheet.
        switch state.customizeAppearanceShortcutTarget {
        case .worktree(let worktreeID, let repositoryID):
          return .send(.requestCustomizeWorktree(worktreeID, repositoryID))
        case .repository(let repositoryID):
          return .send(.requestCustomizeRepository(repositoryID))
        case nil:
          return .none
        }

      case .requestCustomizeWorktree(let worktreeID, let repositoryID):
        guard let repository = state.repositories[id: repositoryID],
          let worktree = repository.worktrees.first(where: { $0.id == worktreeID })
        else {
          repositoriesLogger.warning(
            "requestCustomizeWorktree dropped: unknown wt=\(worktreeID) repo=\(repositoryID)"
          )
          return .none
        }
        // Git main worktree is repository-level (use requestCustomizeRepository instead). The
        // folder synthetic worktree IS the row, so we allow it through.
        if repository.isGitRepository, state.isMainWorktree(worktree) {
          repositoriesLogger.warning(
            "requestCustomizeWorktree dropped: git main worktree is repository-level wt=\(worktreeID)"
          )
          return .none
        }
        let bucket = state.sidebar.currentBucket(of: worktreeID, in: repositoryID)
        let storedItem = bucket.flatMap {
          state.sidebar.sections[repositoryID]?.buckets[$0]?.items[worktreeID]
        }
        // For folder synthetic worktrees, default name = repository name (what the row shows when
        // no override). For git worktrees, default name = branch name.
        let defaultName = repository.isGitRepository ? worktree.name : repository.name
        state.worktreeCustomization = WorktreeCustomizationFeature.State(
          worktreeID: worktreeID,
          repositoryID: repositoryID,
          defaultName: defaultName,
          title: storedItem?.title ?? "",
          color: storedItem?.color
        )
        return .none

      case .worktreeCustomization(.presented(.delegate(.cancel))):
        state.worktreeCustomization = nil
        return .none

      case .worktreeCustomization(
        .presented(.delegate(.save(let worktreeID, let repositoryID, let title, let color)))
      ):
        // Always overwrite (user save intent); falls back to `.unpinned` when the row hasn't been
        // seeded into a bucket yet (folder synthetic before first reconcile, deeplink/palette).
        state.$sidebar.withLock { sidebar in
          sidebar.setCustomization(title: title, color: color, worktree: worktreeID, in: repositoryID)
        }
        syncSidebar(&state)
        state.worktreeCustomization = nil
        return .none

      case .worktreeCustomization(.dismiss):
        state.worktreeCustomization = nil
        return .none

      case .setWorktreeAppearance(let worktreeID, let repositoryID, let title, let color):
        state.$sidebar.withLock { sidebar in
          sidebar.setCustomization(title: title, color: color, worktree: worktreeID, in: repositoryID)
        }
        syncSidebar(&state)
        return .none

      default:
        return .none
      }
    }
  }
}
