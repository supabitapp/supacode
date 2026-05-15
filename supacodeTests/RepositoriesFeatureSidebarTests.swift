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

  @Test func runningScriptsMirrorAggregateDictAcrossSyncs() {
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
    let scriptA = UUID()
    let scriptB = UUID()
    state.runningScriptsByWorktreeID[worktreeID] = [scriptA: .blue]
    RepositoriesFeature.syncSidebar(&state)
    #expect(state.sidebarItems[id: worktreeID]?.runningScripts.map(\.id) == [scriptA])
    #expect(state.sidebarItems[id: worktreeID]?.runningScripts[id: scriptA]?.tint == .blue)

    state.runningScriptsByWorktreeID[worktreeID] = [scriptA: .blue, scriptB: .orange]
    RepositoriesFeature.syncSidebar(&state)
    let expected = [scriptA, scriptB].sorted { $0.uuidString < $1.uuidString }
    #expect(state.sidebarItems[id: worktreeID]?.runningScripts.map(\.id) == expected)

    state.runningScriptsByWorktreeID[worktreeID] = [scriptB: .orange]
    RepositoriesFeature.syncSidebar(&state)
    #expect(state.sidebarItems[id: worktreeID]?.runningScripts.map(\.id) == [scriptB])

    state.runningScriptsByWorktreeID.removeValue(forKey: worktreeID)
    RepositoriesFeature.syncSidebar(&state)
    #expect(state.sidebarItems[id: worktreeID]?.runningScripts.isEmpty == true)
  }

  private func makeState(repository: Repository) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [repository.rootURL]
    return state
  }
}
