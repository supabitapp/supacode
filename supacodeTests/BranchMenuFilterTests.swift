import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

struct BranchMenuFilterTests {
  private func makeMenu() -> BaseRefBranchMenu {
    BaseRefBranchMenu(
      inventory: GitBranchInventory(
        localBranches: ["main", "feature/jira-1234/core-refactoring", "release", "release/v2"],
        remotes: [
          GitRemoteBranchGroup(name: "origin", branches: ["main", "feature/jira-9999/payments"])
        ]
      )
    )
  }

  @Test func allRefsFlattensLocalAndRemoteLeaves() {
    let refs = Set(makeMenu().allRefs())
    #expect(
      refs == [
        "main",
        "feature/jira-1234/core-refactoring",
        "release",
        "release/v2",
        "origin/main",
        "origin/feature/jira-9999/payments",
      ]
    )
  }

  @Test func blankQueryReturnsEveryRef() {
    #expect(makeMenu().refs(matching: "   ").count == 6)
  }

  /// The #387 scenario: type a fragment of a deeply-namespaced branch and find
  /// it without remembering the `jira-1234` prefix or whether it's local/remote.
  @Test func fragmentMatchesDeepBranch() {
    #expect(makeMenu().refs(matching: "core-refactoring") == ["feature/jira-1234/core-refactoring"])
  }

  @Test func filterIsCaseInsensitiveAndSpansRemotes() {
    let refs = Set(makeMenu().refs(matching: "ORIGIN/FEATURE"))
    #expect(refs == ["origin/feature/jira-9999/payments"])
  }

  /// A namespace segment that is itself a branch (`release`) is selectable
  /// alongside its nested child (`release/v2`).
  @Test func namespaceThatIsAlsoABranchIsIncluded() {
    let refs = Set(makeMenu().refs(matching: "release"))
    #expect(refs == ["release", "release/v2"])
  }

  @Test func noMatchReturnsEmpty() {
    #expect(makeMenu().refs(matching: "does-not-exist").isEmpty)
  }
}
