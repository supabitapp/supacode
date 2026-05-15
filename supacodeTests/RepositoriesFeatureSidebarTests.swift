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

  private func makeState(repository: Repository) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [repository.rootURL]
    return state
  }
}
