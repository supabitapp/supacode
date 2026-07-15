import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct MenuBarNotificationListTests {
  @Test func listsUnreadWorktreesWithTheirCountAndRepoSubtitle() {
    let noisy = makeWorktree(id: "/tmp/repo/noisy", name: "noisy")
    let quiet = makeWorktree(id: "/tmp/repo/quiet", name: "quiet")
    var state = RepositoriesFeature.State(
      reconciledRepositories: [makeRepository(worktrees: [noisy, quiet])]
    )
    setRowNotifications(
      &state, id: noisy.id,
      notifications: [
        makeNotification(isRead: false),
        makeNotification(isRead: false),
        makeNotification(isRead: true),
      ]
    )

    let sections = state.computeMenuBarSections()

    #expect(sections.unread == [noisy.id])
    #expect(sections.repositoryTagByID[Repository.ID("/tmp/repo/")]?.repoName == "repo")
    #expect(sections.hasUnread)
  }

  @Test func isEmptyWhenEveryNotificationIsRead() {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    var state = RepositoriesFeature.State(
      reconciledRepositories: [makeRepository(worktrees: [worktree])]
    )
    setRowNotifications(&state, id: worktree.id, notifications: [makeNotification(isRead: true)])

    let sections = state.computeMenuBarSections()

    #expect(sections.unread.isEmpty)
    #expect(!sections.hasUnread)
  }

  @Test func mirrorsTheSidebarActiveSection() {
    let working = makeWorktree(id: "/tmp/repo/working", name: "working")
    var state = RepositoriesFeature.State(
      reconciledRepositories: [makeRepository(worktrees: [working])]
    )
    let instance = AgentPresenceFeature.AgentInstance(agent: .claude, activity: .busy)
    state.sidebarItems[id: working.id]?.agentSnapshot = .init(agents: [instance], isWorking: true)
    state.reconcileSidebarForTesting()

    let sections = state.computeMenuBarSections()

    // The sidebar hoists a tracked agent into Active, so the menu must too.
    #expect(state.sidebarStructure.hoistedRowIDs.contains(working.id))
    #expect(sections.active == [working.id])
    #expect(sections.unread.isEmpty)
  }

  @Test func unreadSectionExcludesRowsTheHighlightSectionsAlreadyShow() {
    let hoisted = makeWorktree(id: "/tmp/repo/hoisted", name: "hoisted")
    var state = RepositoriesFeature.State(
      reconciledRepositories: [makeRepository(worktrees: [hoisted])]
    )
    // Unread plus a tracked agent classifies as Active, so the row is hoisted.
    let instance = AgentPresenceFeature.AgentInstance(agent: .claude, activity: .busy)
    state.sidebarItems[id: hoisted.id]?.agentSnapshot = .init(agents: [instance], isWorking: true)
    setRowNotifications(&state, id: hoisted.id, notifications: [makeNotification(isRead: false)])
    state.reconcileSidebarForTesting()

    let sections = state.computeMenuBarSections()

    #expect(sections.active == [hoisted.id])
    #expect(sections.unread.isEmpty)
    // The dot and "Mark All as Read" must still see the unread row.
    #expect(sections.hasUnread)
  }

  @Test func highlightSectionsAreTakenStraightFromTheSidebarStructure() {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    var state = RepositoriesFeature.State(
      reconciledRepositories: [makeRepository(worktrees: [worktree])]
    )
    state.reconcileSidebarForTesting()

    // Nothing hoisted: the menu must not invent rows the sidebar doesn't show.
    #expect(state.sidebarStructure.hoistedRowIDs.isEmpty)
    let sections = state.computeMenuBarSections()
    #expect(sections.pinned.isEmpty)
    #expect(sections.active.isEmpty)
    #expect(sections.isEmpty)
  }

  @Test func entriesRenderInPinnedThenActiveThenUnreadOrder() {
    let pinned = makeWorktree(id: "/tmp/repo/pinned", name: "pinned")
    let working = makeWorktree(id: "/tmp/repo/working", name: "working")
    let noisy = makeWorktree(id: "/tmp/repo/noisy", name: "noisy")
    var state = RepositoriesFeature.State(
      reconciledRepositories: [makeRepository(worktrees: [pinned, working, noisy])]
    )
    state.$sidebar.withLock { sidebar in
      sidebar.insert(worktree: pinned.id, in: Repository.ID("/tmp/repo/"), bucket: .pinned)
    }
    let instance = AgentPresenceFeature.AgentInstance(agent: .claude, activity: .busy)
    state.sidebarItems[id: working.id]?.agentSnapshot = .init(agents: [instance], isWorking: true)
    setRowNotifications(&state, id: noisy.id, notifications: [makeNotification(isRead: false)])
    state.reconcileSidebarForTesting()

    let sections = state.computeMenuBarSections()
    #expect(sections.pinned == [pinned.id])
    #expect(sections.active == [working.id])
    #expect(sections.unread == [noisy.id])

    // The user-visible section order is the whole point of the flattening.
    #expect(
      sections.entries.map(\.id) == [
        .header("Pinned"), .row(pinned.id),
        .header("Active"), .row(working.id),
        .header("Unread"), .row(noisy.id),
      ]
    )
  }

  @Test func listsUnreadFolderRepositoriesByTheirSyntheticRow() {
    let folderURL = URL(fileURLWithPath: "/tmp/folder")
    let folderID = Repository.folderWorktreeID(for: folderURL)
    var state = RepositoriesFeature.State(
      reconciledRepositories: [
        Repository(
          id: RepositoryID(folderURL.path(percentEncoded: false) + "/"),
          rootURL: folderURL,
          name: "folder",
          worktrees: [
            Worktree(
              id: folderID,
              name: "folder",
              detail: "",
              workingDirectory: folderURL,
              repositoryRootURL: folderURL
            )
          ],
          isGitRepository: false
        )
      ]
    )
    setRowNotifications(&state, id: folderID, notifications: [makeNotification(isRead: false)])

    // A folder's notifications land on its synthetic folder row, which the
    // non-git branch must still surface.
    #expect(state.computeMenuBarSections().unread == [folderID])
  }

  @Test func excludesArchivedWorktreesFromUnread() {
    let archived = makeWorktree(id: "/tmp/repo/archived", name: "archived")
    var state = RepositoriesFeature.State(
      reconciledRepositories: [makeRepository(worktrees: [archived])]
    )
    setRowNotifications(&state, id: archived.id, notifications: [makeNotification(isRead: false)])
    state.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: archived.id,
        in: Repository.ID("/tmp/repo/"),
        bucket: .archived,
        item: .init(archivedAt: Date(timeIntervalSince1970: 1_000_000))
      )
    }
    state.reconcileSidebarForTesting()

    // An archived row has nothing actionable behind it, so it must not light
    // the status item or appear in the menu.
    #expect(state.computeMenuBarSections().unread.isEmpty)
  }

  @Test func postReduceHookRefreshesTheCache() {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    var state = RepositoriesFeature.State(
      reconciledRepositories: [makeRepository(worktrees: [worktree])]
    )
    #expect(state.menuBarSectionsCache.unread.isEmpty)

    setRowNotifications(&state, id: worktree.id, notifications: [makeNotification(isRead: false)])
    state.applyPostReduceCacheRecomputes(.toolbarNotificationGroups)

    #expect(state.menuBarSectionsCache.unread == [worktree.id])

    // Agent activity raises only `.sidebarStructure`, so the cache must key off
    // that flag too, or a row the agent hoists to Active would never reach the
    // menu. The row moves from Unread to Active once the agent lands.
    let instance = AgentPresenceFeature.AgentInstance(agent: .claude, activity: .busy)
    state.sidebarItems[id: worktree.id]?.agentSnapshot = .init(agents: [instance], isWorking: true)
    state.applyPostReduceCacheRecomputes(.sidebarStructure)

    #expect(state.menuBarSectionsCache.unread.isEmpty)
    #expect(state.menuBarSectionsCache.active == [worktree.id])
  }

  // MARK: - Helpers.

  private func makeNotification(isRead: Bool) -> WorktreeTerminalNotification {
    WorktreeTerminalNotification(
      surfaceID: UUID(),
      title: "claude",
      body: "needs your permission",
      createdAt: .distantPast,
      isRead: isRead
    )
  }

  private func setRowNotifications(
    _ state: inout RepositoriesFeature.State,
    id: SidebarItemID,
    notifications: [WorktreeTerminalNotification]
  ) {
    state.sidebarItems[id: id]?.notifications = IdentifiedArrayOf(uniqueElements: notifications)
    state.sidebarItems[id: id]?.hasUnseenNotifications = notifications.contains { !$0.isRead }
  }

  private func makeWorktree(id: String, name: String) -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func makeRepository(worktrees: [Worktree]) -> Repository {
    Repository(
      // `Repository.id` keeps its trailing slash; the worktree IDs don't.
      id: "/tmp/repo/",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }
}
