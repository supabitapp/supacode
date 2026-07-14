import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct MenuBarNotificationListTests {
  @Test func includesWorktreesWithUnreadOrActiveAgentAndExcludesQuietOnes() {
    let list = MenuBarNotificationList.compute(rows: [
      makeRow(name: "unread", unreadCount: 2, hasActiveAgent: false),
      makeRow(name: "active", unreadCount: 0, hasActiveAgent: true),
      makeRow(name: "quiet", unreadCount: 0, hasActiveAgent: false),
    ])

    #expect(list.rows.map(\.worktreeName) == ["unread", "active"])
  }

  @Test func ordersUnreadWorktreesBeforeActiveOnlyOnes() {
    let list = MenuBarNotificationList.compute(rows: [
      makeRow(name: "active", unreadCount: 0, hasActiveAgent: true),
      makeRow(name: "unread", unreadCount: 1, hasActiveAgent: false),
    ])

    #expect(list.rows.first?.worktreeName == "unread")
    #expect(list.rows.last?.worktreeName == "active")
  }

  @Test func ordersByUnreadCountDescendingThenName() {
    let list = MenuBarNotificationList.compute(rows: [
      makeRow(name: "beta", unreadCount: 1, hasActiveAgent: false),
      makeRow(name: "alpha", unreadCount: 3, hasActiveAgent: false),
    ])

    #expect(list.rows.map(\.worktreeName) == ["alpha", "beta"])
  }

  @Test func emptyWhenNothingNeedsAttention() {
    let list = MenuBarNotificationList.compute(rows: [
      makeRow(name: "quiet", unreadCount: 0, hasActiveAgent: false)
    ])

    #expect(list.rows.isEmpty)
    #expect(!list.hasUnread)
  }

  @Test func hasUnreadReflectsAnyUnreadRow() {
    let unreadList = MenuBarNotificationList.compute(rows: [
      makeRow(name: "unread", unreadCount: 1, hasActiveAgent: false)
    ])
    let activeOnlyList = MenuBarNotificationList.compute(rows: [
      makeRow(name: "active", unreadCount: 0, hasActiveAgent: true)
    ])

    #expect(unreadList.hasUnread)
    #expect(!activeOnlyList.hasUnread)
  }

  @Test func agentNotificationHeadlinesSessionTitle() {
    let notification = WorktreeTerminalNotification(
      surfaceID: UUID(),
      title: "claude",
      body: "needs your permission",
      createdAt: Date(timeIntervalSinceReferenceDate: 0)
    )

    #expect(notification.headline(sessionTitle: "fix login bug") == "fix login bug")
  }

  @Test func agentNotificationWithoutSessionTitleFallsBackToDisplayName() {
    let notification = WorktreeTerminalNotification(
      surfaceID: UUID(),
      title: "claude",
      body: "done",
      createdAt: Date(timeIntervalSinceReferenceDate: 0)
    )

    #expect(notification.headline(sessionTitle: nil) == "Claude Code")
  }

  private func makeRow(
    name: String,
    unreadCount: Int,
    hasActiveAgent: Bool
  ) -> MenuBarWorktreeRow {
    MenuBarWorktreeRow(
      id: Worktree.ID("/tmp/repo/\(name)"),
      repoName: "repo",
      worktreeName: name,
      unreadCount: unreadCount,
      hasActiveAgent: hasActiveAgent
    )
  }
}
