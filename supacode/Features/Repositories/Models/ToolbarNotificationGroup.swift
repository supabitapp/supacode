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
}

/// A notification flattened out of the groups, carrying its source for the
/// inspector's single reverse-chronological list.
struct FlatNotificationItem: Identifiable, Equatable, Sendable {
  // A notification is never surfaced under two worktrees, so its id is unique here.
  var id: UUID { notification.id }
  let notification: WorktreeTerminalNotification
  let worktreeID: Worktree.ID
  let repositoryName: String
  let repositoryColor: RepositoryColor?
  let worktreeName: String
  /// A folder's synthetic worktree repeats the repo name; drives dropping the suffix.
  let isFolder: Bool
}

/// A worktree's notifications, for the inspector's optional grouped layout.
struct GroupedNotifications: Identifiable, Equatable {
  var id: Worktree.ID { worktreeID }
  let worktreeID: Worktree.ID
  let repositoryName: String
  let repositoryColor: RepositoryColor?
  let worktreeName: String
  let isFolder: Bool
  let items: [WorktreeTerminalNotification]
}

/// Pure derivations for the flat notification inspector.
enum NotificationInspectorList {
  /// Flattens the grouped cache into one list, newest first, stable on id.
  static func flatten(_ groups: [ToolbarNotificationRepositoryGroup]) -> [FlatNotificationItem] {
    var items: [FlatNotificationItem] = []
    for repository in groups {
      for worktree in repository.worktrees {
        for notification in worktree.notifications {
          items.append(
            FlatNotificationItem(
              notification: notification,
              worktreeID: worktree.id,
              repositoryName: repository.name,
              repositoryColor: repository.color,
              worktreeName: worktree.name,
              isFolder: repository.isFolder
            )
          )
        }
      }
    }
    items.sort { lhs, rhs in
      guard lhs.notification.createdAt == rhs.notification.createdAt else {
        return lhs.notification.createdAt > rhs.notification.createdAt
      }
      return lhs.id.uuidString > rhs.id.uuidString
    }
    return items
  }

  /// Filters the flat list to the active scope and read state.
  /// `.currentWorktree` with no selection lists nothing, not everything.
  static func visibleItems(
    _ items: [FlatNotificationItem],
    scope: NotificationScope,
    selectedWorktreeID: Worktree.ID?,
    unreadOnly: Bool
  ) -> [FlatNotificationItem] {
    var filtered: [FlatNotificationItem] = []
    for item in items {
      guard worktreeInScope(item.worktreeID, scope: scope, selectedWorktreeID: selectedWorktreeID) else {
        continue
      }
      guard !unreadOnly || !item.notification.isRead else { continue }
      filtered.append(item)
    }
    return filtered
  }

  /// Worktree sections for the grouped layout, read from the already-grouped
  /// cache in sidebar order and filtered to the active scope and read state.
  static func visibleGroups(
    _ groups: [ToolbarNotificationRepositoryGroup],
    scope: NotificationScope,
    selectedWorktreeID: Worktree.ID?,
    unreadOnly: Bool
  ) -> [GroupedNotifications] {
    var result: [GroupedNotifications] = []
    for repository in groups {
      for worktree in repository.worktrees
      where worktreeInScope(worktree.id, scope: scope, selectedWorktreeID: selectedWorktreeID) {
        var items: [WorktreeTerminalNotification] = []
        for notification in worktree.notifications where !unreadOnly || !notification.isRead {
          items.append(notification)
        }
        guard !items.isEmpty else { continue }
        result.append(
          GroupedNotifications(
            worktreeID: worktree.id,
            repositoryName: repository.name,
            repositoryColor: repository.color,
            worktreeName: worktree.name,
            isFolder: repository.isFolder,
            items: items
          )
        )
      }
    }
    return result
  }

  /// Unread the retention cap evicted, clamped per surface so a drifted counter can't borrow slack from a sibling.
  static func prunedUnreadCount(
    groups: [ToolbarNotificationRepositoryGroup],
    scope: NotificationScope,
    selectedWorktreeID: Worktree.ID?
  ) -> Int {
    var total = 0
    for repository in groups {
      for worktree in repository.worktrees {
        guard worktreeInScope(worktree.id, scope: scope, selectedWorktreeID: selectedWorktreeID) else {
          continue
        }
        var visibleUnreadBySurface: [UUID: Int] = [:]
        for notification in worktree.notifications where !notification.isRead {
          visibleUnreadBySurface[notification.surfaceID, default: 0] += 1
        }
        for surface in worktree.unseenSurfaces {
          total += max(0, surface.count - (visibleUnreadBySurface[surface.id] ?? 0))
        }
      }
    }
    return total
  }

  /// Worktrees a bulk action targets, from the groups so a pruned-only worktree counts.
  static func actionableWorktreeIDs(
    groups: [ToolbarNotificationRepositoryGroup],
    scope: NotificationScope,
    selectedWorktreeID: Worktree.ID?
  ) -> [Worktree.ID] {
    var ids: [Worktree.ID] = []
    for repository in groups {
      for worktree in repository.worktrees
      where worktreeInScope(worktree.id, scope: scope, selectedWorktreeID: selectedWorktreeID) {
        ids.append(worktree.id)
      }
    }
    return ids
  }

  private static func worktreeInScope(
    _ worktreeID: Worktree.ID,
    scope: NotificationScope,
    selectedWorktreeID: Worktree.ID?
  ) -> Bool {
    switch scope {
    case .all:
      return true
    case .currentWorktree:
      return worktreeID == selectedWorktreeID
    }
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
        let folderRow = isFolder ? repository.folderRowID.flatMap { sidebarItems[id: $0] } : nil
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
