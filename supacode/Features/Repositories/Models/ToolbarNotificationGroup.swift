import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared

struct ToolbarNotificationRepositoryGroup: Identifiable, Equatable {
  let id: Repository.ID
  let name: String
  // Sidebar identity so notification headers render like the sidebar rows.
  let color: RepositoryColor?
  let isFolder: Bool
  let worktrees: [ToolbarNotificationWorktreeGroup]

  var notificationCount: Int {
    worktrees.reduce(0) { count, worktree in
      count + worktree.notifications.count
    }
  }

  var unseenWorktreeCount: Int {
    worktrees.reduce(0) { count, worktree in
      count + (worktree.hasUnseenNotifications ? 1 : 0)
    }
  }
}

struct ToolbarNotificationWorktreeGroup: Identifiable, Equatable {
  let id: Worktree.ID
  let name: String
  let notifications: [WorktreeTerminalNotification]
  let hasUnseenNotifications: Bool
  /// Per-surface outstanding unread, decoupled from `notifications`.
  let unseenSurfaces: [WorktreeUnseenSurface]
  let pullRequestIcon: SidebarPullRequestIcon

  /// Total outstanding unread across surfaces, including pruned notifications.
  var unseenNotificationCount: Int {
    unseenSurfaces.reduce(0) { $0 + $1.count }
  }

  /// Surfaces whose unread notifications were all pruned from the visible log;
  /// the inspector renders one "go to the surface" row per entry.
  var prunedUnseenSurfaces: [WorktreeUnseenSurface] {
    let visibleSurfaceIDs = Set(notifications.map(\.surfaceID))
    return unseenSurfaces.filter { !visibleSurfaceIDs.contains($0.id) }
  }
}

extension RepositoriesFeature.State {
  /// Reads notification data off the per-row `SidebarItemFeature.State`
  /// (populated via `terminalProjectionChanged`) instead of the live
  /// `WorktreeTerminalManager`, so this is a pure reducer-state computation.
  /// Cached on `toolbarNotificationGroupsCache`; views read the cache.
  func computeToolbarNotificationGroups() -> [ToolbarNotificationRepositoryGroup] {
    let repositoriesByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
    var groups: [ToolbarNotificationRepositoryGroup] = []

    // `orderedRepositoryIDs()` is local-only (keyed off `repositoryRoots`); append
    // remote repositories (host-keyed ids) so their worktree notifications also
    // surface in the toolbar bell. Mirrors the sidebar grouping in
    // `RepositoriesFeature+Sidebar`.
    var orderedIDs = orderedRepositoryIDs()
    let coveredIDs = Set(orderedIDs)
    for repository in repositories where repository.host != nil && !coveredIDs.contains(repository.id) {
      orderedIDs.append(repository.id)
    }

    for repositoryID in orderedIDs {
      guard let repository = repositoriesByID[repositoryID] else {
        continue
      }

      let worktreeGroups: [ToolbarNotificationWorktreeGroup] =
        orderedWorktrees(in: repository).compactMap { worktree -> ToolbarNotificationWorktreeGroup? in
          // A row with no visible notifications still surfaces when unread was
          // pruned by the cap, so the inspector can offer the jump-to-surface row.
          guard let row = sidebarItems[id: worktree.id],
            !row.notifications.isEmpty || !row.unseenSurfaces.isEmpty
          else {
            return nil
          }
          // Gate the PR against the worktree branch exactly like the sidebar so a
          // stale PR from a renamed branch doesn't surface the wrong glyph.
          let display = WorktreePullRequestDisplay(worktreeName: row.branchName, pullRequest: row.pullRequest)
          return ToolbarNotificationWorktreeGroup(
            id: worktree.id,
            name: row.resolvedSidebarTitle ?? worktree.name,
            notifications: Array(row.notifications),
            hasUnseenNotifications: row.hasUnseenNotifications,
            unseenSurfaces: row.unseenSurfaces,
            pullRequestIcon: SidebarPullRequestIcon.resolve(display.pullRequest)
          )
        }

      if !worktreeGroups.isEmpty {
        let isFolder = !repository.isGitRepository
        // A folder's title / tint live on its synthetic row, not the repo
        // section; resolve there so a customized folder header matches the sidebar.
        let folderRow = isFolder ? sidebarItems[id: Repository.folderWorktreeID(for: repository.rootURL)] : nil
        let section = sidebar.sections[repositoryID]
        groups.append(
          ToolbarNotificationRepositoryGroup(
            id: repository.id,
            name: isFolder
              ? (folderRow?.resolvedSidebarTitle ?? repository.name)
              : Repository.sidebarDisplayName(custom: section?.title, fallback: repository.name),
            color: isFolder ? folderRow?.customTint : section?.color,
            isFolder: isFolder,
            worktrees: worktreeGroups
          )
        )
      }
    }

    return groups
  }
}
