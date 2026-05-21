import Foundation
import IdentifiedCollections
import OrderedCollections
import Sharing
import Testing

@testable import supacode

@MainActor
struct ToolbarNotificationGroupingTests {
  @Test func groupsNotificationsByRepositoryAndWorktreeInDisplayOrder() {
    let repoAPath = "/tmp/repo-a"
    let repoBPath = "/tmp/repo-b"

    let repoAMain = makeWorktree(id: repoAPath, name: "main", repoRoot: repoAPath)
    let repoAOne = makeWorktree(id: "\(repoAPath)/one", name: "one", repoRoot: repoAPath)
    let repoATwo = makeWorktree(id: "\(repoAPath)/two", name: "two", repoRoot: repoAPath)

    let repoBMain = makeWorktree(id: repoBPath, name: "main", repoRoot: repoBPath)
    let repoBOne = makeWorktree(id: "\(repoBPath)/one", name: "one", repoRoot: repoBPath)

    let repoA = makeRepository(id: repoAPath, name: "Repo A", worktrees: [repoAMain, repoAOne, repoATwo])
    let repoB = makeRepository(id: repoBPath, name: "Repo B", worktrees: [repoBMain, repoBOne])

    var state = RepositoriesFeature.State(reconciledRepositories: [repoA, repoB])
    state.repositoryRoots = [repoA.rootURL, repoB.rootURL]
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repoB.id] = .init()
      sidebar.sections[repoA.id] = .init(
        buckets: [
          .unpinned: .init(
            items: [
              repoATwo.id: .init(),
              repoAOne.id: .init(),
            ]
          )
        ]
      )
    }

    setRowNotifications(
      &state, id: repoAOne.id,
      notifications: [
        WorktreeTerminalNotification(
          surfaceID: UUID(), title: "A1", body: "done", createdAt: .distantPast, isRead: true
        )
      ])
    setRowNotifications(
      &state, id: repoATwo.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "A2", body: "done", createdAt: .distantPast)
      ])
    setRowNotifications(
      &state, id: repoBOne.id,
      notifications: [
        WorktreeTerminalNotification(
          surfaceID: UUID(), title: "B1", body: "done", createdAt: .distantPast, isRead: true
        )
      ])

    let groups = state.computeToolbarNotificationGroups()

    #expect(groups.map(\.id) == [repoB.id, repoA.id])
    #expect(groups[0].worktrees.map(\.id) == [repoBOne.id])
    #expect(groups[1].worktrees.map(\.id) == [repoATwo.id, repoAOne.id])
    #expect(groups[1].unseenWorktreeCount == 1)
  }

  @Test func omitsArchivedAndEmptyNotificationGroups() {
    let repoAPath = "/tmp/repo-a"
    let repoBPath = "/tmp/repo-b"

    let repoAMain = makeWorktree(id: repoAPath, name: "main", repoRoot: repoAPath)
    let repoAArchived = makeWorktree(id: "\(repoAPath)/archived", name: "archived", repoRoot: repoAPath)
    let repoBMain = makeWorktree(id: repoBPath, name: "main", repoRoot: repoBPath)
    let repoBEmpty = makeWorktree(id: "\(repoBPath)/empty", name: "empty", repoRoot: repoBPath)

    let repoA = makeRepository(id: repoAPath, name: "Repo A", worktrees: [repoAMain, repoAArchived])
    let repoB = makeRepository(id: repoBPath, name: "Repo B", worktrees: [repoBMain, repoBEmpty])

    var state = RepositoriesFeature.State(reconciledRepositories: [repoA, repoB])
    state.repositoryRoots = [repoA.rootURL, repoB.rootURL]
    state.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: repoAArchived.id,
        in: repoA.id,
        bucket: .archived,
        item: .init(archivedAt: Date(timeIntervalSince1970: 1_000_000))
      )
    }

    setRowNotifications(
      &state, id: repoAArchived.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "Archived", body: "hidden", createdAt: .distantPast)
      ])

    let groups = state.computeToolbarNotificationGroups()

    #expect(groups.isEmpty)
  }

  @Test func unseenWorktreeCountUsesUnreadNotificationsOnly() {
    let repoPath = "/tmp/repo"
    let main = makeWorktree(id: repoPath, name: "main", repoRoot: repoPath)
    let readOnly = makeWorktree(id: "\(repoPath)/read-only", name: "read-only", repoRoot: repoPath)
    let mixed = makeWorktree(id: "\(repoPath)/mixed", name: "mixed", repoRoot: repoPath)

    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [main, readOnly, mixed])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    setRowNotifications(
      &state, id: readOnly.id,
      notifications: [
        WorktreeTerminalNotification(
          surfaceID: UUID(), title: "Read 1", body: "done", createdAt: .distantPast, isRead: true
        )
      ])
    setRowNotifications(
      &state, id: mixed.id,
      notifications: [
        WorktreeTerminalNotification(
          surfaceID: UUID(), title: "Read 2", body: "done", createdAt: .distantPast, isRead: true
        ),
        WorktreeTerminalNotification(
          surfaceID: UUID(), title: "Unread", body: "new", createdAt: .distantPast, isRead: false
        ),
      ])

    let groups = state.computeToolbarNotificationGroups()

    #expect(groups.count == 1)
    #expect(groups[0].notificationCount == 3)
    #expect(groups[0].unseenWorktreeCount == 1)
  }

  @Test func keepsReadOnlyNotificationsInGroups() {
    let repoPath = "/tmp/repo"
    let main = makeWorktree(id: repoPath, name: "main", repoRoot: repoPath)
    let feature = makeWorktree(id: "\(repoPath)/feature", name: "feature", repoRoot: repoPath)

    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [main, feature])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    setRowNotifications(
      &state, id: feature.id,
      notifications: [
        WorktreeTerminalNotification(
          surfaceID: UUID(), title: "Read", body: "kept", createdAt: .distantPast, isRead: true
        )
      ])

    let groups = state.computeToolbarNotificationGroups()

    #expect(groups.map(\.id) == [repo.id])
    #expect(groups[0].worktrees.map(\.id) == [feature.id])
    #expect(groups[0].unseenWorktreeCount == 0)
  }

  @Test func usesResolvedSidebarTitleWhenCustomTitleIsSet() {
    // A user-set custom title (from `WorktreeCustomizationFeature.save`)
    // flows into `SidebarItemFeature.State.customTitle` via the reconcile
    // pass; the notification popover must show that resolved title, not
    // the raw branch name.
    let repoPath = "/tmp/repo-customized"
    let main = makeWorktree(id: repoPath, name: "main", repoRoot: repoPath)
    let feature = makeWorktree(id: "\(repoPath)/feature", name: "feature/x", repoRoot: repoPath)

    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [main, feature])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    state.sidebarItems[id: feature.id]?.customTitle = "Spicy"

    setRowNotifications(
      &state, id: feature.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "T", body: "done", createdAt: .distantPast)
      ])

    let groups = state.computeToolbarNotificationGroups()

    #expect(groups.first?.worktrees.first?.name == "Spicy")
  }

  private func setRowNotifications(
    _ state: inout RepositoriesFeature.State,
    id: SidebarItemID,
    notifications: [WorktreeTerminalNotification]
  ) {
    let hasUnseen = notifications.contains(where: { !$0.isRead })
    state.sidebarItems[id: id]?.notifications = IdentifiedArrayOf(uniqueElements: notifications)
    state.sidebarItems[id: id]?.hasUnseenNotifications = hasUnseen
  }

  private func makeWorktree(
    id: String,
    name: String,
    repoRoot: String
  ) -> Worktree {
    Worktree(
      id: id,
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: repoRoot)
    )
  }

  private func makeRepository(
    id: String,
    name: String,
    worktrees: [Worktree]
  ) -> Repository {
    Repository(
      id: id,
      rootURL: URL(fileURLWithPath: id),
      name: name,
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }
}
