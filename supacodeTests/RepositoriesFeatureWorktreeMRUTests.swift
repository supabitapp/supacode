import ComposableArchitecture
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct RepositoriesFeatureWorktreeMRUTests {
  @Test func setSingleWorktreeSelection_pushesWorktreeOntoMRU() {
    let worktree = makeWorktree(id: "/tmp/repo-a/wt", name: "wt", repoRoot: "/tmp/repo-a")
    let repository = makeRepository(rootPath: "/tmp/repo-a", name: "A", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])

    state.setSingleWorktreeSelection(worktree.id)

    #expect(state.worktreeMRU == [worktree.id])
  }

  @Test func setSingleWorktreeSelection_dedupesWorktreeInMRUOnRepeat() {
    let wt1 = makeWorktree(id: "/tmp/repo-a/wt-1", name: "wt-1", repoRoot: "/tmp/repo-a")
    let wt2 = makeWorktree(id: "/tmp/repo-a/wt-2", name: "wt-2", repoRoot: "/tmp/repo-a")
    let repo = makeRepository(rootPath: "/tmp/repo-a", name: "A", worktrees: [wt1, wt2])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])

    state.setSingleWorktreeSelection(wt1.id)
    state.setSingleWorktreeSelection(wt2.id)
    state.setSingleWorktreeSelection(wt1.id)

    // Re-selecting wt1 hoists it back to the head without duplicating it.
    #expect(state.worktreeMRU == [wt1.id, wt2.id])
  }

  @Test func setSingleWorktreeSelection_movesPriorWorktreeBehindLatest() {
    // The Cmd+Tab toggle invariant: the two most-recent worktrees swap
    // positions as you bounce between them, across repositories.
    let wtA = makeWorktree(id: "/tmp/repo-a/wt", name: "wt", repoRoot: "/tmp/repo-a")
    let wtB = makeWorktree(id: "/tmp/repo-b/wt", name: "wt", repoRoot: "/tmp/repo-b")
    let repoA = makeRepository(rootPath: "/tmp/repo-a", name: "A", worktrees: [wtA])
    let repoB = makeRepository(rootPath: "/tmp/repo-b", name: "B", worktrees: [wtB])
    var state = RepositoriesFeature.State(reconciledRepositories: [repoA, repoB])

    state.setSingleWorktreeSelection(wtA.id)
    state.setSingleWorktreeSelection(wtB.id)
    state.setSingleWorktreeSelection(wtA.id)

    #expect(state.worktreeMRU == [wtA.id, wtB.id])
  }

  @Test func setSingleWorktreeSelection_nilDoesNotPolluteMRU() {
    let wtA = makeWorktree(id: "/tmp/repo-a/wt", name: "wt", repoRoot: "/tmp/repo-a")
    let repoA = makeRepository(rootPath: "/tmp/repo-a", name: "A", worktrees: [wtA])
    var state = RepositoriesFeature.State(reconciledRepositories: [repoA])

    state.setSingleWorktreeSelection(wtA.id)
    state.setSingleWorktreeSelection(nil)

    // Clearing the selection must leave the MRU head pointing at the
    // worktree the user just stepped out of, not at "nothing." Otherwise
    // a programmatic deselect (e.g. archive flow) would wipe the very
    // recency signal ⌘P relies on.
    #expect(state.worktreeMRU == [wtA.id])
  }

  @Test func sidebarSelectionChange_recordsWorktreeMRU() {
    // The dominant interaction — clicking a worktree in the sidebar — routes
    // through `.selectionChanged` / `reduceSelectionChangedEffect`, NOT
    // `setSingleWorktreeSelection`. If MRU recording only lives in the latter,
    // sidebar navigation never updates `worktreeMRU`, and the ⌘P switcher
    // can't put the worktree the user actually had open at the top. This pins
    // that bug.
    let wt1 = makeWorktree(id: "/tmp/repo-a/wt-1", name: "wt-1", repoRoot: "/tmp/repo-a")
    let wt2 = makeWorktree(id: "/tmp/repo-a/wt-2", name: "wt-2", repoRoot: "/tmp/repo-a")
    let repoA = makeRepository(rootPath: "/tmp/repo-a", name: "A", worktrees: [wt1, wt2])
    var state = RepositoriesFeature.State(reconciledRepositories: [repoA])

    // Simulate a sidebar click landing on the *second* worktree.
    _ = state.reduceSelectionChangedEffect(selections: [.worktree(wt2.id)], focusTerminal: false)

    #expect(state.worktreeMRU == [wt2.id])
  }

  @Test func sidebarSelectionChange_movesPriorWorktreeBehindLatest() {
    let wtA = makeWorktree(id: "/tmp/repo-a/wt", name: "wt", repoRoot: "/tmp/repo-a")
    let wtB = makeWorktree(id: "/tmp/repo-b/wt", name: "wt", repoRoot: "/tmp/repo-b")
    let repoA = makeRepository(rootPath: "/tmp/repo-a", name: "A", worktrees: [wtA])
    let repoB = makeRepository(rootPath: "/tmp/repo-b", name: "B", worktrees: [wtB])
    var state = RepositoriesFeature.State(reconciledRepositories: [repoA, repoB])

    _ = state.reduceSelectionChangedEffect(selections: [.worktree(wtA.id)], focusTerminal: false)
    _ = state.reduceSelectionChangedEffect(selections: [.worktree(wtB.id)], focusTerminal: false)
    _ = state.reduceSelectionChangedEffect(selections: [.worktree(wtA.id)], focusTerminal: false)

    #expect(state.worktreeMRU == [wtA.id, wtB.id])
  }
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
  rootPath: String,
  name: String,
  worktrees: [Worktree]
) -> Repository {
  let rootURL = URL(fileURLWithPath: rootPath)
  return Repository(
    id: RepositoryID(rootURL.path(percentEncoded: false)),
    rootURL: rootURL,
    name: name,
    worktrees: IdentifiedArray(uniqueElements: worktrees)
  )
}
