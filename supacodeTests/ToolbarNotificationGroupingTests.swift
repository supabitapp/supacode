import Foundation
import IdentifiedCollections
import OrderedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
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

  @Test func resolvesRepositoryColorAndCustomTitleFromSection() {
    let repoPath = "/tmp/repo-tinted"
    let main = makeWorktree(id: repoPath, name: "main", repoRoot: repoPath)
    let feature = makeWorktree(id: "\(repoPath)/feature", name: "feature", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [main, feature])

    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repo.id] = .init(title: "Custom Repo", color: .teal)
    }

    setRowNotifications(
      &state, id: feature.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "T", body: "done", createdAt: .distantPast)
      ])

    let group = state.computeToolbarNotificationGroups().first
    #expect(group?.isFolder == false)
    #expect(group?.name == "Custom Repo")
    #expect(group?.color == .teal)
  }

  @Test func resolvesFolderHeaderFromSyntheticRow() {
    // A folder's custom title / tint live on its synthetic row, not the repo
    // section, so the header must resolve there to match the sidebar.
    let folderURL = URL(fileURLWithPath: "/tmp/notif-folder")
    let folderID = Repository.folderWorktreeID(for: folderURL)
    let folderRepo = Repository(
      id: RepositoryID(folderURL.path(percentEncoded: false)),
      rootURL: folderURL,
      name: "notif-folder",
      worktrees: IdentifiedArray(
        uniqueElements: [
          Worktree(
            id: folderID,
            name: "notif-folder",
            detail: "",
            workingDirectory: folderURL,
            repositoryRootURL: folderURL
          )
        ]
      ),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State(reconciledRepositories: [folderRepo])
    state.repositoryRoots = [folderRepo.rootURL]
    state.sidebarItems[id: folderID]?.customTitle = "My Folder"
    state.sidebarItems[id: folderID]?.customTint = .purple

    setRowNotifications(
      &state, id: folderID,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "T", body: "done", createdAt: .distantPast)
      ])

    let group = state.computeToolbarNotificationGroups().first
    #expect(group?.isFolder == true)
    #expect(group?.name == "My Folder")
    #expect(group?.color == .purple)
  }

  @Test func resolvesRemoteFolderHeaderFromHostKeyedSyntheticRow() throws {
    // A remote folder keys its synthetic row off the host-scoped worktree id,
    // so the header must resolve via `folderRowID`, not the local path id.
    let host = RemoteHost(alias: "devbox")
    let folderRepo = RepositoriesFeature.remoteFolderRepository(host: host, remotePath: "/home/me/notes")
    let folderID = try #require(folderRepo.folderRowID)

    var state = RepositoriesFeature.State(reconciledRepositories: [folderRepo])
    state.sidebarItems[id: folderID]?.customTitle = "Remote Notes"
    state.sidebarItems[id: folderID]?.customTint = .purple

    setRowNotifications(
      &state, id: folderID,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "T", body: "done", createdAt: .distantPast)
      ])

    let group = state.computeToolbarNotificationGroups().first
    #expect(group?.isFolder == true)
    #expect(group?.name == "Remote Notes")
    #expect(group?.color == .purple)
  }

  @Test func includesRemoteRepositoryNotifications() {
    // Remote repos are host-keyed and absent from `repositoryRoots` (which is
    // local-only), so `orderedRepositoryIDs()` doesn't list them. The toolbar
    // bell must still surface their notifications.
    let host = RemoteHost(alias: "devbox")
    let repoID = "remote:devbox:/home/me/proj"
    let feature = Worktree(
      id: "devbox:/home/me/proj/feature",
      name: "feature",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/home/me/proj/feature"),
      repositoryRootURL: URL(fileURLWithPath: "/home/me/proj"),
      host: host
    )
    let repo = Repository(
      id: RepositoryID(repoID),
      rootURL: URL(fileURLWithPath: "/home/me/proj"),
      name: "proj",
      worktrees: IdentifiedArray(uniqueElements: [feature]),
      isGitRepository: true,
      host: host
    )
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    // repositoryRoots intentionally left empty, the remote repo isn't in it.

    setRowNotifications(
      &state, id: feature.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "Remote", body: "needs input", createdAt: .distantPast)
      ])

    let groups = state.computeToolbarNotificationGroups()

    #expect(groups.map(\.id) == [RepositoryID(repoID)])
    #expect(groups.first?.worktrees.map(\.id) == [feature.id])
    #expect(groups.first?.unseenWorktreeCount == 1)
  }

  @Test func resolvesPullRequestIconGatedOnBranchLikeTheSidebar() {
    let repoPath = "/tmp/repo-pr"
    let open = makeWorktree(id: "\(repoPath)/open", name: "open", repoRoot: repoPath)
    let plain = makeWorktree(id: "\(repoPath)/plain", name: "plain", repoRoot: repoPath)
    let stale = makeWorktree(id: "\(repoPath)/stale", name: "stale", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [open, plain, stale])

    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    for worktree in [open, plain, stale] {
      setRowNotifications(
        &state, id: worktree.id,
        notifications: [
          WorktreeTerminalNotification(surfaceID: UUID(), title: "N", body: "done", createdAt: .distantPast)
        ])
    }
    // Open PR whose branch matches the worktree -> the open glyph.
    state.sidebarItems[id: open.id]?.branchName = "open"
    state.sidebarItems[id: open.id]?.pullRequest = makePullRequest(state: .open, headRefName: "open")
    // A PR whose branch no longer matches is gated out -> the plain branch glyph.
    state.sidebarItems[id: stale.id]?.branchName = "stale"
    state.sidebarItems[id: stale.id]?.pullRequest = makePullRequest(state: .open, headRefName: "renamed")

    let worktrees = state.computeToolbarNotificationGroups().first?.worktrees ?? []
    let iconsByID = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.id, $0.pullRequestIcon) })
    #expect(iconsByID[open.id] == .open)
    #expect(iconsByID[plain.id] == .branch)
    #expect(iconsByID[stale.id] == .branch)
  }

  private func makePullRequest(
    state: PullRequestState, headRefName: String, isDraft: Bool = false
  ) -> ForgePullRequest {
    ForgePullRequest(
      number: 1,
      title: "PR",
      state: state,
      additions: 0,
      deletions: 0,
      isDraft: isDraft,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      mergedAt: nil,
      url: "https://example.com/pull/1",
      headRefName: headRefName,
      baseRefName: "main",
      commitsCount: 0,
      authorLogin: nil,
      statusCheckRollup: nil,
      mergeQueueEntry: nil
    )
  }

  @Test func unseenCountCountsSurfacesWhoseNotificationsWereAllPruned() {
    let repoPath = "/tmp/repo"
    let main = makeWorktree(id: repoPath, name: "main", repoRoot: repoPath)
    let feature = makeWorktree(id: "\(repoPath)/feature", name: "feature", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [main, feature])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    // Unread arrived but the cap pruned every one of its notifications from the log.
    let surfaceID = UUID()
    state.sidebarItems[id: feature.id]?.notifications = []
    state.sidebarItems[id: feature.id]?.hasUnseenNotifications = true
    state.sidebarItems[id: feature.id]?.unseenSurfaces = [WorktreeUnseenSurface(id: surfaceID, count: 3)]

    let worktree = state.computeToolbarNotificationGroups().first?.worktrees.first
    #expect(worktree?.unseenNotificationCount == 3)
  }

  @Test func unseenCountReflectsSurfaceWithVisibleNotification() {
    let repoPath = "/tmp/repo"
    let main = makeWorktree(id: repoPath, name: "main", repoRoot: repoPath)
    let feature = makeWorktree(id: "\(repoPath)/feature", name: "feature", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [main, feature])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    let surfaceID = UUID()
    setRowNotifications(
      &state, id: feature.id,
      notifications: [
        WorktreeTerminalNotification(
          surfaceID: surfaceID, title: "Unread", body: "new", createdAt: .distantPast, isRead: false
        )
      ])
    state.sidebarItems[id: feature.id]?.unseenSurfaces = [WorktreeUnseenSurface(id: surfaceID, count: 1)]

    let worktree = state.computeToolbarNotificationGroups().first?.worktrees.first
    #expect(worktree?.unseenNotificationCount == 1)
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
      id: WorktreeID(id),
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
      id: RepositoryID(id),
      rootURL: URL(fileURLWithPath: id),
      name: name,
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }
}

@MainActor
struct ScriptMenuIdentityTests {
  // The running-script set drives the cached NSMenu's `.id`, so dropping it
  // would let the toolbar dropdown go stale after a signal-based stop (#573).
  @Test func runningScriptSetParticipatesInIdentity() {
    let running = UUID()
    let base = WorktreeDetailView.ScriptMenuIdentity(
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      repoFingerprints: [],
      globalFingerprints: [],
      runningScriptIDs: []
    )
    let withRunning = WorktreeDetailView.ScriptMenuIdentity(
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      repoFingerprints: [],
      globalFingerprints: [],
      runningScriptIDs: [running]
    )

    #expect(base != withRunning)
    #expect(
      base
        == WorktreeDetailView.ScriptMenuIdentity(
          rootURL: URL(fileURLWithPath: "/tmp/repo"),
          repoFingerprints: [],
          globalFingerprints: [],
          runningScriptIDs: []
        ))
  }
}

@MainActor
struct NotificationInspectorListTests {
  @Test func flattenSortsNewestFirstAndDenormalizesSource() {
    let repoPath = "/tmp/repo"
    let featureA = makeWorktree(id: "\(repoPath)/a", name: "feature-a", repoRoot: repoPath)
    let featureB = makeWorktree(id: "\(repoPath)/b", name: "feature-b", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [featureA, featureB])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    setRowNotifications(
      &state, id: featureA.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "old", body: "x", createdAt: at(100)),
        WorktreeTerminalNotification(surfaceID: UUID(), title: "new", body: "x", createdAt: at(300)),
      ])
    setRowNotifications(
      &state, id: featureB.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "mid", body: "x", createdAt: at(200))
      ])
    // The group name resolves from the sidebar title, so set a custom one to
    // assert flatten denormalizes it onto the row deterministically.
    state.sidebarItems[id: featureA.id]?.customTitle = "Feature A"

    let items = NotificationInspectorList.flatten(state.computeToolbarNotificationGroups())

    #expect(items.map(\.notification.title) == ["new", "mid", "old"])
    #expect(items.first?.worktreeID == featureA.id)
    #expect(items.first?.repositoryName == "Repo")
    #expect(items.first?.worktreeName == "Feature A")
  }

  @Test func visibleItemsAppliesScope() {
    let repoPath = "/tmp/repo"
    let featureA = makeWorktree(id: "\(repoPath)/a", name: "feature-a", repoRoot: repoPath)
    let featureB = makeWorktree(id: "\(repoPath)/b", name: "feature-b", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [featureA, featureB])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    setRowNotifications(
      &state, id: featureA.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "a1", body: "x", createdAt: at(300)),
        WorktreeTerminalNotification(surfaceID: UUID(), title: "a2", body: "x", createdAt: at(100)),
      ])
    setRowNotifications(
      &state, id: featureB.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "b1", body: "x", createdAt: at(200))
      ])

    let items = NotificationInspectorList.flatten(state.computeToolbarNotificationGroups())

    #expect(
      NotificationInspectorList.visibleItems(
        items, scope: .all, selectedWorktreeID: featureA.id, unreadOnly: false
      ).count == 3)
    #expect(
      NotificationInspectorList.visibleItems(
        items, scope: .currentWorktree, selectedWorktreeID: featureA.id, unreadOnly: false
      ).map(\.notification.title) == ["a1", "a2"])
    #expect(
      NotificationInspectorList.visibleItems(
        items, scope: .currentWorktree, selectedWorktreeID: featureB.id, unreadOnly: false
      ).map(\.notification.title) == ["b1"])
    // No selection under the current-worktree scope lists nothing, not everything.
    #expect(
      NotificationInspectorList.visibleItems(
        items, scope: .currentWorktree, selectedWorktreeID: nil, unreadOnly: false
      ).isEmpty)
  }

  @Test func visibleItemsUnreadOnlyHidesReadAcrossScopes() {
    let repoPath = "/tmp/repo"
    let featureA = makeWorktree(id: "\(repoPath)/a", name: "feature-a", repoRoot: repoPath)
    let featureB = makeWorktree(id: "\(repoPath)/b", name: "feature-b", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [featureA, featureB])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    setRowNotifications(
      &state, id: featureA.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "a1", body: "x", createdAt: at(300)),
        WorktreeTerminalNotification(surfaceID: UUID(), title: "a2", body: "x", createdAt: at(100), isRead: true),
      ])
    setRowNotifications(
      &state, id: featureB.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "b1", body: "x", createdAt: at(200)),
        WorktreeTerminalNotification(surfaceID: UUID(), title: "b2", body: "x", createdAt: at(50), isRead: true),
      ])

    let items = NotificationInspectorList.flatten(state.computeToolbarNotificationGroups())

    // Under `.all`, unread from every worktree survives (selection is ignored) and
    // all read entries drop, in global time order.
    #expect(
      NotificationInspectorList.visibleItems(
        items, scope: .all, selectedWorktreeID: featureA.id, unreadOnly: true
      ).map(\.notification.title) == ["a1", "b1"])
    // Current-worktree scope narrows the same filter to just the selected worktree's unread.
    #expect(
      NotificationInspectorList.visibleItems(
        items, scope: .currentWorktree, selectedWorktreeID: featureA.id, unreadOnly: true
      ).map(\.notification.title) == ["a1"])
    #expect(
      NotificationInspectorList.visibleItems(
        items, scope: .currentWorktree, selectedWorktreeID: featureB.id, unreadOnly: true
      ).map(\.notification.title) == ["b1"])
  }

  @Test func prunedUnreadCountAndActionableWorktreesRespectScope() {
    let repoPath = "/tmp/repo"
    let featureA = makeWorktree(id: "\(repoPath)/a", name: "feature-a", repoRoot: repoPath)
    let featureB = makeWorktree(id: "\(repoPath)/b", name: "feature-b", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [featureA, featureB])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    // Both worktrees have only pruned unread (no visible notifications).
    for (worktree, count) in [(featureA, 3), (featureB, 2)] {
      state.sidebarItems[id: worktree.id]?.notifications = []
      state.sidebarItems[id: worktree.id]?.hasUnseenNotifications = true
      state.sidebarItems[id: worktree.id]?.unseenSurfaces = [WorktreeUnseenSurface(id: UUID(), count: count)]
    }

    let groups = state.computeToolbarNotificationGroups()

    #expect(
      NotificationInspectorList.prunedUnreadCount(groups: groups, scope: .all, selectedWorktreeID: nil) == 5)
    #expect(
      NotificationInspectorList.prunedUnreadCount(
        groups: groups, scope: .currentWorktree, selectedWorktreeID: featureA.id) == 3)
    // Pruned-only worktrees still count as actionable so bulk actions clear them.
    #expect(
      Set(NotificationInspectorList.actionableWorktreeIDs(groups: groups, scope: .all, selectedWorktreeID: nil))
        == Set([featureA.id, featureB.id]))
    #expect(
      NotificationInspectorList.actionableWorktreeIDs(
        groups: groups, scope: .currentWorktree, selectedWorktreeID: featureB.id) == [featureB.id])
  }

  @Test func flatCacheRebuildsWithTheGroupsCache() {
    let repoPath = "/tmp/repo"
    let featureA = makeWorktree(id: "\(repoPath)/a", name: "feature-a", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [featureA])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    setRowNotifications(
      &state, id: featureA.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "n1", body: "x", createdAt: at(100)),
        WorktreeTerminalNotification(surfaceID: UUID(), title: "n2", body: "x", createdAt: at(200)),
      ])

    #expect(state.toolbarNotificationItemsCache.isEmpty)
    state.recomputeToolbarNotificationGroupsIfChanged()

    #expect(
      state.toolbarNotificationItemsCache
        == NotificationInspectorList.flatten(state.toolbarNotificationGroupsCache))
    #expect(state.toolbarNotificationItemsCache.map(\.notification.title) == ["n2", "n1"])
  }

  @Test func prunedUnreadCountFoldsPartiallyPrunedSurfaces() {
    let repoPath = "/tmp/repo"
    let feature = makeWorktree(id: "\(repoPath)/feature", name: "feature", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [feature])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    // Surface X keeps 1 visible unread but has 3 outstanding (2 evicted); surface
    // Y is fully pruned (2). Pruned = (3 - 1) + 2 = 4, not the 2 a surface-level
    // count would report.
    let surfaceX = UUID()
    setRowNotifications(
      &state, id: feature.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: surfaceX, title: "X", body: "x", createdAt: at(100))
      ])
    state.sidebarItems[id: feature.id]?.unseenSurfaces = [
      WorktreeUnseenSurface(id: surfaceX, count: 3),
      WorktreeUnseenSurface(id: UUID(), count: 2),
    ]

    let groups = state.computeToolbarNotificationGroups()
    #expect(NotificationInspectorList.prunedUnreadCount(groups: groups, scope: .all, selectedWorktreeID: nil) == 4)
  }

  @Test func prunedUnreadCountClampsPerSurfaceUnderCounterDrift() {
    let repoPath = "/tmp/repo"
    let feature = makeWorktree(id: "\(repoPath)/feature", name: "feature", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [feature])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    // Surface X's counter (1) has drifted below its 2 visible unread rows; surface
    // Y is fully pruned (5). Per-surface clamping keeps X at 0, so pruned = 5, not
    // the 4 a pooled worktree-level subtraction would report.
    let surfaceX = UUID()
    setRowNotifications(
      &state, id: feature.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: surfaceX, title: "X1", body: "x", createdAt: at(100)),
        WorktreeTerminalNotification(surfaceID: surfaceX, title: "X2", body: "x", createdAt: at(110)),
      ])
    state.sidebarItems[id: feature.id]?.unseenSurfaces = [
      WorktreeUnseenSurface(id: surfaceX, count: 1),
      WorktreeUnseenSurface(id: UUID(), count: 5),
    ]

    let groups = state.computeToolbarNotificationGroups()
    #expect(NotificationInspectorList.prunedUnreadCount(groups: groups, scope: .all, selectedWorktreeID: nil) == 5)
  }

  @Test func flattenTieBreaksEqualTimestampsByDescendingID() {
    let repoPath = "/tmp/repo"
    let feature = makeWorktree(id: "\(repoPath)/feature", name: "feature", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [feature])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let high = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
    setRowNotifications(
      &state, id: feature.id,
      notifications: [
        WorktreeTerminalNotification(id: low, surfaceID: UUID(), title: "low", body: "x", createdAt: at(100)),
        WorktreeTerminalNotification(id: high, surfaceID: UUID(), title: "high", body: "x", createdAt: at(100)),
      ])

    // Equal timestamps fall back to descending uuidString for a stable order.
    let items = NotificationInspectorList.flatten(state.computeToolbarNotificationGroups())
    #expect(items.map(\.notification.title) == ["high", "low"])
  }

  @Test func flattenSortsAcrossRepositoriesAndCarriesEachSource() {
    let repoAPath = "/tmp/repo-a"
    let repoBPath = "/tmp/repo-b"
    let featureA = makeWorktree(id: "\(repoAPath)/a", name: "a", repoRoot: repoAPath)
    let featureB = makeWorktree(id: "\(repoBPath)/b", name: "b", repoRoot: repoBPath)
    let repoA = makeRepository(id: repoAPath, name: "Repo A", worktrees: [featureA])
    let repoB = makeRepository(id: repoBPath, name: "Repo B", worktrees: [featureB])
    var state = RepositoriesFeature.State(reconciledRepositories: [repoA, repoB])
    state.repositoryRoots = [repoA.rootURL, repoB.rootURL]
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repoA.id] = .init(title: "Repo A", color: .teal)
      sidebar.sections[repoB.id] = .init(title: "Repo B", color: .purple)
    }

    setRowNotifications(
      &state, id: featureA.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "a-old", body: "x", createdAt: at(100)),
        WorktreeTerminalNotification(surfaceID: UUID(), title: "a-new", body: "x", createdAt: at(300)),
      ])
    setRowNotifications(
      &state, id: featureB.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "b-mid", body: "x", createdAt: at(200))
      ])

    let items = NotificationInspectorList.flatten(state.computeToolbarNotificationGroups())
    // Global time sort ignores repository grouping.
    #expect(items.map(\.notification.title) == ["a-new", "b-mid", "a-old"])
    let byTitle = Dictionary(uniqueKeysWithValues: items.map { ($0.notification.title, $0) })
    #expect(byTitle["a-new"]?.repositoryName == "Repo A")
    #expect(byTitle["a-new"]?.repositoryColor == .teal)
    #expect(byTitle["b-mid"]?.repositoryName == "Repo B")
    #expect(byTitle["b-mid"]?.repositoryColor == .purple)
  }

  @Test func visibleGroupsReadsGroupedCacheScoped() {
    let repoPath = "/tmp/repo"
    let featureA = makeWorktree(id: "\(repoPath)/a", name: "a", repoRoot: repoPath)
    let featureB = makeWorktree(id: "\(repoPath)/b", name: "b", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [featureA, featureB])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    setRowNotifications(
      &state, id: featureA.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "a1", body: "x", createdAt: at(100))
      ])
    setRowNotifications(
      &state, id: featureB.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "b1", body: "x", createdAt: at(200))
      ])

    let groups = state.computeToolbarNotificationGroups()
    let all = NotificationInspectorList.visibleGroups(groups, scope: .all, selectedWorktreeID: nil, unreadOnly: false)
    #expect(Set(all.map(\.worktreeID)) == Set([featureA.id, featureB.id]))
    #expect(all.allSatisfy { !$0.items.isEmpty })

    let current = NotificationInspectorList.visibleGroups(
      groups, scope: .currentWorktree, selectedWorktreeID: featureB.id, unreadOnly: false)
    #expect(current.map(\.worktreeID) == [featureB.id])
    #expect(current.first?.items.map(\.title) == ["b1"])
  }

  @Test func visibleGroupsUnreadOnlyDropsReadAndEmptiedSections() {
    let repoPath = "/tmp/repo"
    let featureA = makeWorktree(id: "\(repoPath)/a", name: "feature-a", repoRoot: repoPath)
    let featureB = makeWorktree(id: "\(repoPath)/b", name: "feature-b", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [featureA, featureB])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    setRowNotifications(
      &state, id: featureA.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "a1", body: "x", createdAt: at(300)),
        WorktreeTerminalNotification(surfaceID: UUID(), title: "a2", body: "x", createdAt: at(100), isRead: true),
      ])
    setRowNotifications(
      &state, id: featureB.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "b1", body: "x", createdAt: at(200), isRead: true)
      ])

    let groups = state.computeToolbarNotificationGroups()
    let sections = NotificationInspectorList.visibleGroups(
      groups, scope: .all, selectedWorktreeID: nil, unreadOnly: true)

    // featureB is all-read, so its section drops entirely; featureA keeps only unread.
    #expect(sections.map(\.worktreeID) == [featureA.id])
    #expect(sections.first?.items.map(\.title) == ["a1"])
  }

  @Test func visibleGroupsUnreadOnlyCombinesWithCurrentWorktreeScope() {
    let repoPath = "/tmp/repo"
    let featureA = makeWorktree(id: "\(repoPath)/a", name: "feature-a", repoRoot: repoPath)
    let featureB = makeWorktree(id: "\(repoPath)/b", name: "feature-b", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [featureA, featureB])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    setRowNotifications(
      &state, id: featureA.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "a1", body: "x", createdAt: at(300)),
        WorktreeTerminalNotification(surfaceID: UUID(), title: "a2", body: "x", createdAt: at(100), isRead: true),
      ])
    setRowNotifications(
      &state, id: featureB.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "b1", body: "x", createdAt: at(200))
      ])

    let groups = state.computeToolbarNotificationGroups()
    let sections = NotificationInspectorList.visibleGroups(
      groups, scope: .currentWorktree, selectedWorktreeID: featureA.id, unreadOnly: true)

    // Scope keeps only the selected worktree; unread-only drops its read entry.
    #expect(sections.map(\.worktreeID) == [featureA.id])
    #expect(sections.first?.items.map(\.title) == ["a1"])
  }

  @Test func visibleGroupsExcludesPrunedOnlyWorktree() {
    let repoPath = "/tmp/repo"
    let pruned = makeWorktree(id: "\(repoPath)/pruned", name: "pruned", repoRoot: repoPath)
    let live = makeWorktree(id: "\(repoPath)/live", name: "live", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [pruned, live])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    // `pruned` has outstanding unread but no visible notifications (cap-evicted).
    state.sidebarItems[id: pruned.id]?.notifications = []
    state.sidebarItems[id: pruned.id]?.hasUnseenNotifications = true
    state.sidebarItems[id: pruned.id]?.unseenSurfaces = [WorktreeUnseenSurface(id: UUID(), count: 2)]
    setRowNotifications(
      &state, id: live.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "l1", body: "x", createdAt: at(100))
      ])

    let groups = state.computeToolbarNotificationGroups()
    let sections = NotificationInspectorList.visibleGroups(
      groups, scope: .all, selectedWorktreeID: nil, unreadOnly: false)
    // The pruned-only worktree renders no section but stays actionable for bulk actions.
    #expect(sections.map(\.worktreeID) == [live.id])
    #expect(
      Set(NotificationInspectorList.actionableWorktreeIDs(groups: groups, scope: .all, selectedWorktreeID: nil))
        == Set([pruned.id, live.id]))
  }

  @Test func visibleGroupsAcrossRepositoriesCarriesSourceAndOrder() {
    let repoAPath = "/tmp/repo-a"
    let repoBPath = "/tmp/repo-b"
    let featureA = makeWorktree(id: "\(repoAPath)/a", name: "a", repoRoot: repoAPath)
    let featureB = makeWorktree(id: "\(repoBPath)/b", name: "b", repoRoot: repoBPath)
    let repoA = makeRepository(id: repoAPath, name: "Repo A", worktrees: [featureA])
    let repoB = makeRepository(id: repoBPath, name: "Repo B", worktrees: [featureB])
    var state = RepositoriesFeature.State(reconciledRepositories: [repoA, repoB])
    state.repositoryRoots = [repoA.rootURL, repoB.rootURL]
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repoA.id] = .init(title: "Repo A", color: .teal)
      sidebar.sections[repoB.id] = .init(title: "Repo B", color: .purple)
    }
    setRowNotifications(
      &state, id: featureA.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "a-new", body: "x", createdAt: at(300)),
        WorktreeTerminalNotification(surfaceID: UUID(), title: "a-old", body: "x", createdAt: at(100)),
      ])
    setRowNotifications(
      &state, id: featureB.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "b1", body: "x", createdAt: at(200))
      ])

    let groups = state.computeToolbarNotificationGroups()
    let sections = NotificationInspectorList.visibleGroups(
      groups, scope: .all, selectedWorktreeID: nil, unreadOnly: false)
    #expect(sections.map(\.worktreeID) == [featureA.id, featureB.id])
    let sectionA = sections.first { $0.worktreeID == featureA.id }
    #expect(sectionA?.repositoryName == "Repo A")
    #expect(sectionA?.repositoryColor == .teal)
    // Grouped items keep the stored order (not the flat list's global sort).
    #expect(sectionA?.items.map(\.title) == ["a-new", "a-old"])
    #expect(sections.first { $0.worktreeID == featureB.id }?.repositoryColor == .purple)
  }

  @Test func visibleGroupsCurrentWorktreeWithNilSelectionIsEmpty() {
    let repoPath = "/tmp/repo"
    let feature = makeWorktree(id: "\(repoPath)/a", name: "a", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [feature])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]
    setRowNotifications(
      &state, id: feature.id,
      notifications: [
        WorktreeTerminalNotification(surfaceID: UUID(), title: "a1", body: "x", createdAt: at(100))
      ])

    let groups = state.computeToolbarNotificationGroups()
    #expect(
      NotificationInspectorList.visibleGroups(
        groups, scope: .currentWorktree, selectedWorktreeID: nil, unreadOnly: false
      ).isEmpty)
  }

  private func at(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
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

  private func makeWorktree(id: String, name: String, repoRoot: String) -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: repoRoot)
    )
  }

  private func makeRepository(id: String, name: String, worktrees: [Worktree]) -> Repository {
    Repository(
      id: RepositoryID(id),
      rootURL: URL(fileURLWithPath: id),
      name: name,
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }
}

struct NotificationScopeSettingsTests {
  @Test func defaultsToAll() {
    #expect(GlobalSettings.default.notificationScope == .all)
  }

  @Test func absentKeyDecodesToAll() throws {
    let data = try JSONEncoder().encode(GlobalSettings.default)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "notificationScope")
    let stripped = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: stripped)
    #expect(decoded.notificationScope == .all)
  }

  @Test func roundTripsCurrentWorktree() throws {
    var settings = GlobalSettings.default
    settings.notificationScope = .currentWorktree
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(decoded.notificationScope == .currentWorktree)
  }

  @Test func presentButUnknownScopeDecodesToAllWithoutThrowing() throws {
    // A scope written by a newer build (or corruption) must fall back, not throw
    // and reset the whole settings file.
    let data = try JSONEncoder().encode(GlobalSettings.default)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["notificationScope"] = "nonsense"
    let mangled = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: mangled)
    #expect(decoded.notificationScope == .all)
  }

  @Test func groupingDefaultsToOff() {
    #expect(GlobalSettings.default.notificationsGroupedByWorktree == false)
  }

  @Test func groupingRoundTrips() throws {
    var settings = GlobalSettings.default
    settings.notificationsGroupedByWorktree = true
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(decoded.notificationsGroupedByWorktree)
  }

  @Test func groupingAbsentKeyDecodesToOff() throws {
    let data = try JSONEncoder().encode(GlobalSettings.default)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "notificationsGroupedByWorktree")
    let stripped = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: stripped)
    #expect(decoded.notificationsGroupedByWorktree == false)
  }

  @Test func unreadOnlyDefaultsToOff() {
    #expect(GlobalSettings.default.notificationsUnreadOnly == false)
  }

  @Test func unreadOnlyRoundTrips() throws {
    var settings = GlobalSettings.default
    settings.notificationsUnreadOnly = true
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(decoded.notificationsUnreadOnly)
  }

  @Test func unreadOnlyAbsentKeyDecodesToOff() throws {
    let data = try JSONEncoder().encode(GlobalSettings.default)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "notificationsUnreadOnly")
    let stripped = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: stripped)
    #expect(decoded.notificationsUnreadOnly == false)
  }
}
