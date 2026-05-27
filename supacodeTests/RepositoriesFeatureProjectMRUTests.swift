import ComposableArchitecture
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct RepositoriesFeatureProjectMRUTests {
  @Test func setSingleWorktreeSelection_pushesContainingProjectOntoMRU() {
    let worktree = makeWorktree(id: "/tmp/repo-a/wt", name: "wt", repoRoot: "/tmp/repo-a")
    let repository = makeRepository(rootPath: "/tmp/repo-a", name: "A", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])

    state.setSingleWorktreeSelection(worktree.id)

    #expect(state.projectMRU == [repository.id])
    #expect(state.lastWorktreeByProject[repository.id] == worktree.id)
  }

  @Test func setSingleWorktreeSelection_dedupesProjectInMRUOnRepeat() {
    let wt1 = makeWorktree(id: "/tmp/repo-a/wt-1", name: "wt-1", repoRoot: "/tmp/repo-a")
    let wt2 = makeWorktree(id: "/tmp/repo-a/wt-2", name: "wt-2", repoRoot: "/tmp/repo-a")
    let repo = makeRepository(rootPath: "/tmp/repo-a", name: "A", worktrees: [wt1, wt2])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])

    state.setSingleWorktreeSelection(wt1.id)
    state.setSingleWorktreeSelection(wt2.id)

    #expect(state.projectMRU == [repo.id])
    #expect(state.lastWorktreeByProject[repo.id] == wt2.id)
  }

  @Test func setSingleWorktreeSelection_movesPriorProjectBehindLatest() {
    let wtA = makeWorktree(id: "/tmp/repo-a/wt", name: "wt", repoRoot: "/tmp/repo-a")
    let wtB = makeWorktree(id: "/tmp/repo-b/wt", name: "wt", repoRoot: "/tmp/repo-b")
    let repoA = makeRepository(rootPath: "/tmp/repo-a", name: "A", worktrees: [wtA])
    let repoB = makeRepository(rootPath: "/tmp/repo-b", name: "B", worktrees: [wtB])
    var state = RepositoriesFeature.State(reconciledRepositories: [repoA, repoB])

    state.setSingleWorktreeSelection(wtA.id)
    state.setSingleWorktreeSelection(wtB.id)
    state.setSingleWorktreeSelection(wtA.id)

    #expect(state.projectMRU == [repoA.id, repoB.id])
    #expect(state.lastWorktreeByProject[repoA.id] == wtA.id)
    #expect(state.lastWorktreeByProject[repoB.id] == wtB.id)
  }

  @Test func setSingleWorktreeSelection_nilDoesNotPolluteMRU() {
    let wtA = makeWorktree(id: "/tmp/repo-a/wt", name: "wt", repoRoot: "/tmp/repo-a")
    let repoA = makeRepository(rootPath: "/tmp/repo-a", name: "A", worktrees: [wtA])
    var state = RepositoriesFeature.State(reconciledRepositories: [repoA])

    state.setSingleWorktreeSelection(wtA.id)
    state.setSingleWorktreeSelection(nil)

    // Clearing the selection must leave the MRU head pointing at the
    // project the user just stepped out of, not at "nothing." Otherwise
    // a programmatic deselect (e.g. archive flow) would wipe the very
    // recency signal Cmd+P relies on.
    #expect(state.projectMRU == [repoA.id])
    #expect(state.lastWorktreeByProject[repoA.id] == wtA.id)
  }
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
  rootPath: String,
  name: String,
  worktrees: [Worktree]
) -> Repository {
  let rootURL = URL(fileURLWithPath: rootPath)
  return Repository(
    id: rootURL.path(percentEncoded: false),
    rootURL: rootURL,
    name: name,
    worktrees: IdentifiedArray(uniqueElements: worktrees)
  )
}
