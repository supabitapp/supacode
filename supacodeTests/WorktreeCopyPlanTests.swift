import Testing

@testable import supacode

struct WorktreeCopyPlanTests {
  @Test func subtractsExcludedFromEachCategory() {
    let plan = WorktreeCopyPlan.survivors(
      ignoredCandidates: ["build/app.o", ".env", "cache.db"],
      untrackedCandidates: ["notes.txt", "secret.env"],
      excluded: ["build/app.o", "cache.db", "secret.env"]
    )
    #expect(plan.ignored == [".env"])
    #expect(plan.untracked == ["notes.txt"])
  }

  @Test func prunesTheReposOwnGitEntries() {
    let plan = WorktreeCopyPlan.survivors(
      ignoredCandidates: [".git", ".git/config", "keep"],
      untrackedCandidates: [],
      excluded: []
    )
    #expect(plan.ignored == ["keep"])
  }

  @Test func prunesTrailingSlashNestedRepositoryEntries() {
    // Git collapses a nested repo / worktree to a single trailing-slash entry;
    // copying it verbatim would recurse its whole tree.
    let plan = WorktreeCopyPlan.survivors(
      ignoredCandidates: ["nested-repo/", "vendor/lib.a"],
      untrackedCandidates: ["submodule-dir/"],
      excluded: []
    )
    #expect(plan.ignored == ["vendor/lib.a"])
    #expect(plan.untracked.isEmpty)
  }

  @Test func keepsDotGitignoreWhilePruningTheGitDirectory() {
    // Only `.git` and its contents are pruned; sibling dotfiles like `.gitignore`
    // / `.gitmodules` are legitimate untracked files that must still copy. Pins
    // the `hasPrefix(".git/")` boundary against a careless narrowing to `.git`.
    let plan = WorktreeCopyPlan.survivors(
      ignoredCandidates: [".git", ".git/config", ".gitignore", ".gitmodules"],
      untrackedCandidates: [],
      excluded: []
    )
    #expect(plan.ignored == [".gitignore", ".gitmodules"])
  }

  @Test func placesAPathSharedByBothCategoriesInIgnoredOnly() {
    // A path can't land in both lists (which would copy / count it twice); the
    // shared `seen` gives ignored precedence.
    let plan = WorktreeCopyPlan.survivors(
      ignoredCandidates: ["shared", "onlyignored"],
      untrackedCandidates: ["shared", "onlyuntracked"],
      excluded: []
    )
    #expect(plan.ignored == ["shared", "onlyignored"])
    #expect(plan.untracked == ["onlyuntracked"])
  }

  @Test func dedupesRepeatedCandidates() {
    let plan = WorktreeCopyPlan.survivors(
      ignoredCandidates: [".env", ".env", "config"],
      untrackedCandidates: [],
      excluded: []
    )
    #expect(plan.ignored == [".env", "config"])
  }

  @Test func isEmptyWhenEverythingFiltered() {
    let plan = WorktreeCopyPlan.survivors(
      ignoredCandidates: ["a", "b"],
      untrackedCandidates: ["c"],
      excluded: ["a", "b", "c"]
    )
    #expect(plan.isEmpty)
  }
}
