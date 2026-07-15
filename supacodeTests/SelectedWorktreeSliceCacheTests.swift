import ComposableArchitecture
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

/// Pins the load-bearing #289 contract: storms on the focused row that
/// only touch agent / surface / notification fields must NOT mutate the
/// cached `selectedWorktreeSlice` or `toolbarNotificationGroupsCache`.
@MainActor
struct SelectedWorktreeSliceCacheTests {
  @Test func agentSnapshotChangeOnFocusedRowDoesNotMutateSlice() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)
    state.reconcileSidebarForTesting()
    let sliceBefore = state.selectedWorktreeSlice
    #expect(sliceBefore != nil, "Cache must be populated for the focused row")

    let store = TestStore(initialState: state) { RepositoriesFeature() }

    // Agent storm: only mutates `agentSnapshot`. Slice excludes it, so the
    // post-reduce diff must not invalidate the cache.
    await store.send(
      .sidebarItems(.element(id: worktree.id, action: .agentSnapshotChanged(.init())))
    )
    #expect(store.state.selectedWorktreeSlice == sliceBefore)
  }

  @Test func terminalProjectionChangeOnFocusedRowDoesNotMutateSlice() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)
    state.reconcileSidebarForTesting()
    let sliceBefore = state.selectedWorktreeSlice

    let store = TestStore(initialState: state) { RepositoriesFeature() }
    let surfaceID = UUID()
    await store.send(
      .sidebarItems(
        .element(
          id: worktree.id,
          action: .terminalProjectionChanged(
            WorktreeRowProjection(
              surfaceIDs: [surfaceID],
              isProgressBusy: false,
              hasUnseenNotifications: false,
              notifications: [],
              runningScripts: []
            )
          )
        )
      )
    ) {
      $0.sidebarItems[id: worktree.id]?.hasTerminalProjection = true
      $0.sidebarItems[id: worktree.id]?.surfaceIDs = [surfaceID]
      $0.applyPostReduceCacheRecomputes()
    }

    // The slice recompute runs (projections can carry `runningScripts`), but a
    // surfaces-only change must diff to the same slice value.
    #expect(store.state.selectedWorktreeSlice == sliceBefore)
  }

  @Test func agentSnapshotChangeOnFocusedRowDoesNotMutateNotificationCache() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)
    state.reconcileSidebarForTesting()
    let cacheBefore = state.toolbarNotificationGroupsCache

    let store = TestStore(initialState: state) { RepositoriesFeature() }
    await store.send(
      .sidebarItems(.element(id: worktree.id, action: .agentSnapshotChanged(.init())))
    )

    #expect(store.state.toolbarNotificationGroupsCache == cacheBefore)
  }

  @Test func runningScriptProjectionOnFocusedRowMutatesSlice() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)
    state.reconcileSidebarForTesting()
    let scriptID = UUID()
    let store = TestStore(initialState: state) { RepositoriesFeature() }

    await store.send(
      .sidebarItems(
        .element(
          id: worktree.id,
          action: .terminalProjectionChanged(
            WorktreeRowProjection(
              surfaceIDs: [],
              isProgressBusy: false,
              hasUnseenNotifications: false,
              notifications: [],
              runningScripts: [.init(id: scriptID, tint: .blue)]
            )
          )
        )
      )
    ) {
      $0.sidebarItems[id: worktree.id]?.hasTerminalProjection = true
      $0.sidebarItems[id: worktree.id]?.runningScripts = [.init(id: scriptID, tint: .blue)]
      $0.applyPostReduceCacheRecomputes()
    }

    // Verify the cache picked up the new running script (sanity that the
    // recompute path actually fires for this action). This is the toolbar
    // dropdown's Run/Stop signal (#573).
    #expect(store.state.selectedWorktreeSlice?.runningScripts.contains(where: { $0.id == scriptID }) == true)
  }

  @Test func pullRequestChangeRefreshesNotificationGlyphCache() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)
    // A notification makes the row appear in the cache; the branch feeds PR gating.
    state.sidebarItems[id: worktree.id]?.notifications = [
      WorktreeTerminalNotification(surfaceID: UUID(), title: "N", body: "b", createdAt: .distantPast)
    ]
    state.sidebarItems[id: worktree.id]?.hasUnseenNotifications = true
    state.sidebarItems[id: worktree.id]?.branchName = "wt"
    state.reconcileSidebarForTesting()
    #expect(state.toolbarNotificationGroupsCache.first?.worktrees.first?.pullRequestIcon == .branch)

    let store = TestStore(initialState: state) { RepositoriesFeature() }
    store.exhaustivity = .off
    let pullRequest = GithubPullRequest(
      number: 1, title: "PR", state: "OPEN", additions: 0, deletions: 0, isDraft: false,
      reviewDecision: nil, mergeable: nil, mergeStateStatus: nil, updatedAt: nil,
      url: "https://example.com/pull/1", headRefName: "wt", baseRefName: "main",
      commitsCount: 0, authorLogin: nil, statusCheckRollup: nil, mergeQueueEntry: nil
    )
    await store.send(
      .sidebarItems(.element(id: worktree.id, action: .pullRequestChanged(pullRequest, branchAtQueryTime: "wt")))
    )

    // The PR change must re-arm the notification cache, not just the selection slice.
    #expect(store.state.toolbarNotificationGroupsCache.first?.worktrees.first?.pullRequestIcon == .open)
  }

  private func makeWorktree(id: String, repoRoot: String) -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: "wt",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: repoRoot)
    )
  }

  private func makeRepository(id: String, worktrees: [Worktree]) -> Repository {
    Repository(
      id: RepositoryID(id),
      rootURL: URL(fileURLWithPath: id),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }
}
