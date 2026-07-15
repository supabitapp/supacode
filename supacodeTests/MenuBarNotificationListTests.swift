import ComposableArchitecture
import Foundation
import IdentifiedCollections
import OrderedCollections
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
    // The dot and "Mark Unread Notifications as Read" must still see the unread row.
    #expect(sections.hasUnread)
  }

  @Test func menuIsEmptyWhenNothingNeedsAttention() {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    var state = RepositoriesFeature.State(
      reconciledRepositories: [makeRepository(worktrees: [worktree])]
    )
    state.reconcileSidebarForTesting()

    // A plain worktree with no pin, agent, or notification classifies nowhere,
    // so the menu must not invent a row for it.
    let sections = state.computeMenuBarSections()
    #expect(sections.pinned.isEmpty)
    #expect(sections.active.isEmpty)
    #expect(sections.isEmpty)
  }

  @Test func hoistsPinnedAndActiveEvenWhenSidebarGroupingIsOff() {
    // Scope `defaultAppStorage = .inMemory` so the grouping-toggle writes don't
    // leak into the parallel suite via the process-global UserDefaults.
    withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarGroupPinnedRows) var groupPinned
      @Shared(.sidebarGroupActiveRows) var groupActive
      $groupPinned.withLock { $0 = false }
      $groupActive.withLock { $0 = false }

      let pinned = makeWorktree(id: "/tmp/repo/pinned", name: "pinned")
      let working = makeWorktree(id: "/tmp/repo/working", name: "working")
      var state = RepositoriesFeature.State(
        reconciledRepositories: [makeRepository(worktrees: [pinned, working])]
      )
      state.$sidebar.withLock { sidebar in
        sidebar.insert(worktree: pinned.id, in: Repository.ID("/tmp/repo/"), bucket: .pinned)
        sidebar.sections[Repository.ID("/tmp/repo/"), default: .init()].title = "Pretty"
        sidebar.sections[Repository.ID("/tmp/repo/"), default: .init()].color = .teal
      }
      let instance = AgentPresenceFeature.AgentInstance(agent: .claude, activity: .busy)
      state.sidebarItems[id: working.id]?.agentSnapshot = .init(agents: [instance], isWorking: true)
      state.reconcileSidebarForTesting()

      // With the toggles honored, the sidebar itself hoists nothing, so the
      // menu populating proves it no longer follows the grouping preference.
      #expect(state.sidebarStructure.hoistedRowIDs.isEmpty)

      // The menu lists Pinned and Active regardless, and each hoisted row keeps
      // its `repo · worktree` subtitle tag, custom name and color included.
      let sections = state.computeMenuBarSections()
      #expect(sections.pinned == [pinned.id])
      #expect(sections.active == [working.id])
      let tag = sections.repositoryTagByID[Repository.ID("/tmp/repo/")]
      #expect(tag?.repoName == "Pretty")
      #expect(tag?.repoColor == .teal)
    }
  }

  @Test func doesNotDuplicateAnActiveOrPinnedRowIntoUnreadWhenGroupingOff() {
    withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebarGroupPinnedRows) var groupPinned
      @Shared(.sidebarGroupActiveRows) var groupActive
      $groupPinned.withLock { $0 = false }
      $groupActive.withLock { $0 = false }

      let hot = makeWorktree(id: "/tmp/repo/hot", name: "hot")
      let pinned = makeWorktree(id: "/tmp/repo/pinned", name: "pinned")
      var state = RepositoriesFeature.State(
        reconciledRepositories: [makeRepository(worktrees: [hot, pinned])]
      )
      state.$sidebar.withLock { sidebar in
        sidebar.insert(worktree: pinned.id, in: Repository.ID("/tmp/repo/"), bucket: .pinned)
      }
      let instance = AgentPresenceFeature.AgentInstance(agent: .claude, activity: .busy)
      state.sidebarItems[id: hot.id]?.agentSnapshot = .init(agents: [instance], isWorking: true)
      // Both the Active row and the Pinned row are also unread.
      setRowNotifications(&state, id: hot.id, notifications: [makeNotification(isRead: false)])
      setRowNotifications(&state, id: pinned.id, notifications: [makeNotification(isRead: false)])
      state.reconcileSidebarForTesting()

      // Grouping off drops both rows from every sidebar highlight, so the menu's
      // Unread must dedupe against its own forced hoists, not the sidebar's.
      #expect(state.sidebarStructure.hoistedRowIDs.isEmpty)

      let sections = state.computeMenuBarSections()
      #expect(sections.active == [hot.id])
      #expect(sections.pinned == [pinned.id])
      // Neither the Active nor the Pinned unread row doubles into Unread.
      #expect(sections.unread.isEmpty)
      #expect(sections.hasUnread)
    }
  }

  @Test func listsUnreadRemoteFolderByItsHostKeyedSyntheticRow() {
    let host = RemoteHost(alias: "devbox")
    let folderURL = URL(fileURLWithPath: "/remote/folder")
    // A remote folder's row is keyed off the host-scoped worktree id, which
    // differs from the local path id the old lookup used and never matched.
    let syntheticID = WorktreeID("devbox/remote/folder")
    let folderRow = Worktree(
      id: syntheticID,
      kind: .folder,
      name: "folder",
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL,
      host: host
    )
    var state = RepositoriesFeature.State(
      reconciledRepositories: [
        Repository(
          id: RepositoryID("devbox/remote/folder"),
          rootURL: folderURL,
          name: "folder",
          worktrees: IdentifiedArray(uniqueElements: [folderRow]),
          isGitRepository: false,
          host: host
        )
      ]
    )
    setRowNotifications(&state, id: syntheticID, notifications: [makeNotification(isRead: false)])

    #expect(syntheticID != Repository.folderWorktreeID(for: folderURL))
    let sections = state.computeMenuBarSections()
    #expect(sections.unread == [syntheticID])
    // The unread-only remote row still carries its host authority in the tag.
    #expect(sections.repositoryTagByID[RepositoryID("devbox/remote/folder")]?.hostInfo == host.displayAuthority)
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
