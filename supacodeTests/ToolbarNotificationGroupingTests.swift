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

    var state = RepositoriesFeature.State(repositories: [repoA, repoB])
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

    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    manager.state(for: repoAOne).notifications = [
      WorktreeTerminalNotification(
        surfaceId: UUID(), title: "A1", body: "done", createdAt: .distantPast, isRead: true
      )
    ]
    manager.state(for: repoATwo).notifications = [
      WorktreeTerminalNotification(surfaceId: UUID(), title: "A2", body: "done", createdAt: .distantPast)
    ]
    manager.state(for: repoBOne).notifications = [
      WorktreeTerminalNotification(
        surfaceId: UUID(), title: "B1", body: "done", createdAt: .distantPast, isRead: true
      )
    ]

    let groups = state.toolbarNotificationGroups(terminalManager: manager)

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

    var state = RepositoriesFeature.State(repositories: [repoA, repoB])
    state.repositoryRoots = [repoA.rootURL, repoB.rootURL]
    state.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: repoAArchived.id,
        in: repoA.id,
        bucket: .archived,
        item: .init(archivedAt: Date(timeIntervalSince1970: 1_000_000))
      )
    }

    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    manager.state(for: repoAArchived).notifications = [
      WorktreeTerminalNotification(surfaceId: UUID(), title: "Archived", body: "hidden", createdAt: .distantPast)
    ]

    let groups = state.toolbarNotificationGroups(terminalManager: manager)

    #expect(groups.isEmpty)
  }

  @Test func unseenWorktreeCountUsesUnreadNotificationsOnly() {
    let repoPath = "/tmp/repo"
    let main = makeWorktree(id: repoPath, name: "main", repoRoot: repoPath)
    let readOnly = makeWorktree(id: "\(repoPath)/read-only", name: "read-only", repoRoot: repoPath)
    let mixed = makeWorktree(id: "\(repoPath)/mixed", name: "mixed", repoRoot: repoPath)

    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [main, readOnly, mixed])
    var state = RepositoriesFeature.State(repositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    manager.state(for: readOnly).notifications = [
      WorktreeTerminalNotification(
        surfaceId: UUID(), title: "Read 1", body: "done", createdAt: .distantPast, isRead: true
      )
    ]
    manager.state(for: mixed).notifications = [
      WorktreeTerminalNotification(
        surfaceId: UUID(), title: "Read 2", body: "done", createdAt: .distantPast, isRead: true
      ),
      WorktreeTerminalNotification(
        surfaceId: UUID(), title: "Unread", body: "new", createdAt: .distantPast, isRead: false
      ),
    ]

    let groups = state.toolbarNotificationGroups(terminalManager: manager)

    #expect(groups.count == 1)
    #expect(groups[0].notificationCount == 3)
    #expect(groups[0].unseenWorktreeCount == 1)
  }

  @Test func keepsReadOnlyNotificationsInGroups() {
    let repoPath = "/tmp/repo"
    let main = makeWorktree(id: repoPath, name: "main", repoRoot: repoPath)
    let feature = makeWorktree(id: "\(repoPath)/feature", name: "feature", repoRoot: repoPath)

    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [main, feature])
    var state = RepositoriesFeature.State(repositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    manager.state(for: feature).notifications = [
      WorktreeTerminalNotification(
        surfaceId: UUID(), title: "Read", body: "kept", createdAt: .distantPast, isRead: true
      )
    ]

    let groups = state.toolbarNotificationGroups(terminalManager: manager)

    #expect(groups.map(\.id) == [repo.id])
    #expect(groups[0].worktrees.map(\.id) == [feature.id])
    #expect(groups[0].unseenWorktreeCount == 0)
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
