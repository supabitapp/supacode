import ComposableArchitecture
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct RepositoriesFeatureSidebarTests {
  @Test func reconcileClearsPullRequestWatermarkOnBranchRename() {
    let worktreeID = "/tmp/repo/wt-feature"
    let repoID = "/tmp/repo/"
    let original = Worktree(
      id: worktreeID,
      name: "feature",
      detail: "",
      workingDirectory: URL(fileURLWithPath: worktreeID),
      repositoryRootURL: URL(fileURLWithPath: repoID)
    )
    var state = makeState(
      repository: Repository(
        id: repoID,
        rootURL: URL(fileURLWithPath: repoID),
        name: "repo",
        worktrees: IdentifiedArray(uniqueElements: [original])
      ))
    RepositoriesFeature.syncSidebar(&state)
    state.sidebarItems[id: worktreeID]?.pullRequestBranchAtQueryTime = "feature"

    let renamed = Worktree(
      id: worktreeID,
      name: "feature-renamed",
      detail: "",
      workingDirectory: URL(fileURLWithPath: worktreeID),
      repositoryRootURL: URL(fileURLWithPath: repoID)
    )
    state.repositories[id: repoID] = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: repoID),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [renamed])
    )
    RepositoriesFeature.syncSidebar(&state)

    #expect(state.sidebarItems[id: worktreeID]?.branchName == "feature-renamed")
    #expect(state.sidebarItems[id: worktreeID]?.pullRequestBranchAtQueryTime == nil)
  }

  @Test func runningScriptsSurviveReconcile() {
    let worktreeID = "/tmp/repo/wt-feature"
    let repoID = "/tmp/repo/"
    let worktree = Worktree(
      id: worktreeID,
      name: "feature",
      detail: "",
      workingDirectory: URL(fileURLWithPath: worktreeID),
      repositoryRootURL: URL(fileURLWithPath: repoID)
    )
    var state = makeState(
      repository: Repository(
        id: repoID,
        rootURL: URL(fileURLWithPath: repoID),
        name: "repo",
        worktrees: IdentifiedArray(uniqueElements: [worktree])
      ))
    RepositoriesFeature.syncSidebar(&state)
    let scriptA = UUID()
    let scriptB = UUID()
    state.sidebarItems[id: worktreeID]?.runningScripts[id: scriptA] = .init(id: scriptA, tint: .blue)
    RepositoriesFeature.syncSidebar(&state)
    #expect(state.sidebarItems[id: worktreeID]?.runningScripts.map(\.id) == [scriptA])
    #expect(state.sidebarItems[id: worktreeID]?.runningScripts[id: scriptA]?.tint == .blue)

    state.sidebarItems[id: worktreeID]?.runningScripts[id: scriptB] = .init(id: scriptB, tint: .orange)
    RepositoriesFeature.syncSidebar(&state)
    #expect(state.sidebarItems[id: worktreeID]?.runningScripts.map(\.id) == [scriptA, scriptB])

    state.sidebarItems[id: worktreeID]?.runningScripts.remove(id: scriptA)
    RepositoriesFeature.syncSidebar(&state)
    #expect(state.sidebarItems[id: worktreeID]?.runningScripts.map(\.id) == [scriptB])

    state.sidebarItems[id: worktreeID]?.runningScripts.removeAll()
    RepositoriesFeature.syncSidebar(&state)
    #expect(state.sidebarItems[id: worktreeID]?.runningScripts.isEmpty == true)
  }

  @Test func inFlightRowSurvivesTransientRosterDrop() {
    let worktreeID = "/tmp/repo/wt-feature"
    let repoID = "/tmp/repo/"
    let worktree = Worktree(
      id: worktreeID,
      name: "feature",
      detail: "",
      workingDirectory: URL(fileURLWithPath: worktreeID),
      repositoryRootURL: URL(fileURLWithPath: repoID)
    )
    var state = makeState(
      repository: Repository(
        id: repoID,
        rootURL: URL(fileURLWithPath: repoID),
        name: "repo",
        worktrees: IdentifiedArray(uniqueElements: [worktree])
      ))
    RepositoriesFeature.syncSidebar(&state)
    state.sidebarItems[id: worktreeID]?.lifecycle = .archiving
    XCTAssertSidebarConsistent(state)

    // Simulate transient roster drop (e.g. archive script clearing the
    // worktree from the live roster mid-flight).
    state.repositories[id: repoID] = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: repoID),
      name: "repo",
      worktrees: []
    )
    RepositoriesFeature.syncSidebar(&state)

    // The row is carried forward because lifecycle != .idle.
    #expect(state.sidebarItems[id: worktreeID]?.lifecycle == .archiving)
    XCTAssertSidebarConsistent(state)

    // Roster restores the worktree.
    state.repositories[id: repoID] = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: repoID),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    RepositoriesFeature.syncSidebar(&state)

    // Lifecycle is preserved across the round-trip.
    #expect(state.sidebarItems[id: worktreeID]?.lifecycle == .archiving)
    XCTAssertSidebarConsistent(state)
  }

  @Test func pullRequestsLoadedClearsWatermarkOnIdenticalPullRequest() async {
    let repoID = "/tmp/repo"
    let worktreeID = "/tmp/repo/wt-feature"
    let worktree = Worktree(
      id: worktreeID,
      name: "feature",
      detail: "",
      workingDirectory: URL(fileURLWithPath: worktreeID),
      repositoryRootURL: URL(fileURLWithPath: repoID)
    )
    let repository = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: repoID),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    let pullRequest = GithubPullRequest(
      number: 7,
      title: "Live",
      state: "OPEN",
      additions: 1,
      deletions: 0,
      isDraft: false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      url: "https://example.com/pull/7",
      headRefName: "feature",
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "tester",
      statusCheckRollup: nil
    )
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.sidebarItems[id: worktreeID]?.pullRequest = pullRequest
    state.sidebarItems[id: worktreeID]?.pullRequestBranchAtQueryTime = "feature"
    state.inFlightPullRequestBranchSnapshotsByRepositoryID[repoID] = [worktreeID: "feature"]

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repoID,
        pullRequestsByWorktreeID: [worktreeID: pullRequest]
      )
    )
    await store.receive(\.sidebarItems[id: worktreeID].pullRequestChanged) {
      $0.sidebarItems[id: worktreeID]?.pullRequestBranchAtQueryTime = nil
    }
    await store.finish()
    #expect(store.state.sidebarItems[id: worktreeID]?.pullRequest == pullRequest)
  }

  @Test func pullRequestsLoadedClearsWatermarkForQueriedButMissingWorktree() async {
    // Worktree was included in the request snapshot but absent from the response
    // (e.g. branch deleted upstream); the row must still receive
    // `pullRequestChanged` so its watermark clears and the next refresh is eligible.
    let repoID = "/tmp/repo"
    let worktreeID = "/tmp/repo/wt-feature"
    let worktree = Worktree(
      id: worktreeID,
      name: "feature",
      detail: "",
      workingDirectory: URL(fileURLWithPath: worktreeID),
      repositoryRootURL: URL(fileURLWithPath: repoID)
    )
    let repository = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: repoID),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.sidebarItems[id: worktreeID]?.pullRequestBranchAtQueryTime = "feature"
    state.inFlightPullRequestBranchSnapshotsByRepositoryID[repoID] = [worktreeID: "feature"]

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoryPullRequestsLoaded(repositoryID: repoID, pullRequestsByWorktreeID: [:])
    )
    await store.receive(\.sidebarItems[id: worktreeID].pullRequestChanged) {
      $0.sidebarItems[id: worktreeID]?.pullRequestBranchAtQueryTime = nil
    }
    await store.finish()
    #expect(store.state.sidebarItems[id: worktreeID]?.pullRequest == nil)
  }

  private func makeState(repository: Repository) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [repository.rootURL]
    return state
  }
}
