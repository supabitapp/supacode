import Testing

@testable import supacode

struct GitClientBranchAvailabilityTests {
  @Test func parsesEachState() {
    let output = """
      refs/heads/busy:/tmp/worktrees/busy
      refs/heads/feature/x:
      """
    #expect(GitClient.parseBranchAvailability(output, branch: "feature/x") == .reusable)
    #expect(GitClient.parseBranchAvailability(output, branch: "busy") == .checkedOut("/tmp/worktrees/busy"))
    #expect(GitClient.parseBranchAvailability(output, branch: "missing") == .absent)
  }

  @Test func matchesOnlyTheExactRef() {
    // `refs/heads/feature` as a pattern also lists the refs nested under it.
    #expect(GitClient.parseBranchAvailability("refs/heads/feature/x:", branch: "feature") == .absent)
    #expect(GitClient.parseBranchAvailability("refs/heads/Feature:", branch: "feature") == .absent)
  }
}
