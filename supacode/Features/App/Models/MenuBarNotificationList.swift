import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared

/// One worktree that currently wants attention in the menu bar dropdown:
/// it has unread notifications, a live agent, or both.
struct MenuBarWorktreeRow: Identifiable, Equatable {
  let id: Worktree.ID
  let repoName: String
  let worktreeName: String
  let unreadCount: Int
  let hasActiveAgent: Bool
}

/// Menu-sized projection of the worktrees needing attention: those with unread
/// notifications or an active agent, unread ones first. The dropdown lists
/// *which* sessions want attention (system notifications already carry the
/// message text), so this intentionally does not repeat notification bodies.
struct MenuBarNotificationList: Equatable {
  var rows: [MenuBarWorktreeRow] = []
  /// True when any listed worktree has unread notifications, so "Mark All as
  /// Read" can gate on it.
  var hasUnread = false

  static func compute(rows input: [MenuBarWorktreeRow]) -> Self {
    let attention = input.filter { $0.unreadCount > 0 || $0.hasActiveAgent }
    let sorted = attention.sorted { lhs, rhs in
      let lhsUnread = lhs.unreadCount > 0
      let rhsUnread = rhs.unreadCount > 0
      // Unread worktrees float above active-only ones.
      if lhsUnread != rhsUnread { return lhsUnread }
      if lhs.unreadCount != rhs.unreadCount { return lhs.unreadCount > rhs.unreadCount }
      return lhs.worktreeName.localizedCaseInsensitiveCompare(rhs.worktreeName) == .orderedAscending
    }
    return Self(rows: sorted, hasUnread: attention.contains { $0.unreadCount > 0 })
  }
}

extension RepositoriesFeature.State {
  /// Candidate rows for the menu bar dropdown — one per worktree that has a
  /// sidebar row, carrying its unread count and agent-activity flag. Mirrors the
  /// repository grouping of `computeToolbarNotificationGroups` so repo/worktree
  /// names match the sidebar. `MenuBarNotificationList.compute` does the
  /// attention filtering and ordering.
  func menuBarWorktreeRows() -> [MenuBarWorktreeRow] {
    let repositoriesByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
    var orderedIDs = orderedRepositoryIDs()
    let coveredIDs = Set(orderedIDs)
    for repository in repositories where repository.host != nil && !coveredIDs.contains(repository.id) {
      orderedIDs.append(repository.id)
    }

    var rows: [MenuBarWorktreeRow] = []
    for repositoryID in orderedIDs {
      guard let repository = repositoriesByID[repositoryID] else { continue }
      let isFolder = !repository.isGitRepository
      let folderRow = isFolder ? sidebarItems[id: Repository.folderWorktreeID(for: repository.rootURL)] : nil
      let section = sidebar.sections[repositoryID]
      let repoName =
        isFolder
        ? (folderRow?.resolvedSidebarTitle ?? repository.name)
        : Repository.sidebarDisplayName(custom: section?.title, fallback: repository.name)

      for worktree in orderedWorktrees(in: repository) {
        guard let row = sidebarItems[id: worktree.id] else { continue }
        let unread = row.notifications.count { !$0.isRead }
        guard unread > 0 || row.hasAgentActivity else { continue }
        rows.append(
          MenuBarWorktreeRow(
            id: worktree.id,
            repoName: repoName,
            worktreeName: row.resolvedSidebarTitle ?? worktree.name,
            unreadCount: unread,
            hasActiveAgent: row.hasAgentActivity
          )
        )
      }
    }
    return rows
  }
}

extension WorktreeTerminalNotification {
  /// Display headline: agent notifications carry the agent slug as `title`, so
  /// headline with the live session (tab) title when one exists, else the agent
  /// display name. Non-agent notifications keep their own title (it's real
  /// content, not a slug).
  func headline(sessionTitle: String?) -> String {
    let agent = SkillAgent(rawValue: title.lowercased())
    let fallbackTitle = agent?.displayName ?? (title.isEmpty ? "Terminal" : title)
    // An unrenamed tab is titled with the bare process name ("claude"); map
    // that back to the display name rather than headlining the raw slug.
    let resolvedSessionTitle = sessionTitle.map { SkillAgent(rawValue: $0.lowercased())?.displayName ?? $0 }
    return (agent != nil ? resolvedSessionTitle : nil) ?? fallbackTitle
  }
}
