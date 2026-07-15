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
    state.sidebarItems[id: open.id]?.pullRequest = makePullRequest(state: "OPEN", headRefName: "open")
    // A PR whose branch no longer matches is gated out -> the plain branch glyph.
    state.sidebarItems[id: stale.id]?.branchName = "stale"
    state.sidebarItems[id: stale.id]?.pullRequest = makePullRequest(state: "OPEN", headRefName: "renamed")

    let worktrees = state.computeToolbarNotificationGroups().first?.worktrees ?? []
    let iconsByID = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.id, $0.pullRequestIcon) })
    #expect(iconsByID[open.id] == .open)
    #expect(iconsByID[plain.id] == .branch)
    #expect(iconsByID[stale.id] == .branch)
  }

  private func makePullRequest(state: String, headRefName: String, isDraft: Bool = false) -> GithubPullRequest {
    GithubPullRequest(
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
      url: "https://example.com/pull/1",
      headRefName: headRefName,
      baseRefName: "main",
      commitsCount: 0,
      authorLogin: nil,
      statusCheckRollup: nil,
      mergeQueueEntry: nil
    )
  }

  @Test func prunedUnreadSurfacesFormAGroupWithSyntheticRows() {
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
    #expect(worktree?.prunedUnseenSurfaces.map(\.id) == [surfaceID])
  }

  @Test func surfaceWithVisibleNotificationIsNotSynthesized() {
    let repoPath = "/tmp/repo"
    let main = makeWorktree(id: repoPath, name: "main", repoRoot: repoPath)
    let feature = makeWorktree(id: "\(repoPath)/feature", name: "feature", repoRoot: repoPath)
    let repo = makeRepository(id: repoPath, name: "Repo", worktrees: [main, feature])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.repositoryRoots = [repo.rootURL]

    // The surface still has a visible notification, so no synthetic row is added.
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
    #expect(worktree?.prunedUnseenSurfaces.isEmpty == true)
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
