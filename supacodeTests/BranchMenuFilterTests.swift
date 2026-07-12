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

  /// Flattening preserves the sorted tree order (locals before remotes, a
  /// namespace branch before its nested child) the windowed picker relies on.
  @Test func allRefsFlattensInSortedTreeOrder() {
    #expect(
      makeMenu().allRefs() == [
        "feature/jira-1234/core-refactoring",
        "main",
        "release",
        "release/v2",
        "origin/feature/jira-9999/payments",
        "origin/main",
      ]
    )
  }

  @Test func blankQueryReturnsEveryRef() {
    #expect(makeMenu().refs(matching: "   ").count == 6)
  }

  /// The default branch is hoisted out of the Local submenu as a quick pick, but
  /// it must still be findable through search.
  @Test func searchSurfacesTheHoistedDefaultBranch() {
    let menu = BaseRefBranchMenu(
      inventory: GitBranchInventory(
        localBranches: ["main", "feature/x"],
        remotes: [GitRemoteBranchGroup(name: "origin", branches: ["main"])]
      ),
      hoistedLocalBranch: "main"
    )
    #expect(menu.refs(matching: "main") == ["main", "origin/main"])
  }

  /// A hoisted name that is not actually a local branch is never offered.
  @Test func allRefsOmitsHoistedBranchAbsentFromInventory() {
    let menu = BaseRefBranchMenu(
      inventory: GitBranchInventory(localBranches: ["dev"], remotes: []),
      hoistedLocalBranch: "main"
    )
    #expect(menu.allRefs() == ["dev"])
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
  /// alongside its nested child (`release/v2`), and precedes it in order.
  @Test func namespaceThatIsAlsoABranchIsIncluded() {
    #expect(makeMenu().refs(matching: "release") == ["release", "release/v2"])
  }

  @Test func noMatchReturnsEmpty() {
    #expect(makeMenu().refs(matching: "does-not-exist").isEmpty)
  }

  @Test func rowDisplayStripsRemotePrefixIntoScope() {
    let display = BaseRefBranchMenu.rowDisplay(
      for: "origin/feature/jira-9999/payments",
      remoteNames: ["origin"]
    )
    #expect(display.name == "feature/jira-9999/payments")
    #expect(display.scope == "origin")
  }

  @Test func rowDisplayTagsLocalRefs() {
    let display = BaseRefBranchMenu.rowDisplay(for: "feature/jira-1234/core-refactoring", remoteNames: ["origin"])
    #expect(display.name == "feature/jira-1234/core-refactoring")
    #expect(display.scope == "Local")
  }

  /// The trailing slash is load-bearing: a remote name that is only a prefix of
  /// another remote must not strip, and the longer match wins.
  @Test func rowDisplayDoesNotStripRemoteNameThatIsNotAFullSegment() {
    let display = BaseRefBranchMenu.rowDisplay(
      for: "origin-mirror/main",
      remoteNames: ["origin", "origin-mirror"]
    )
    #expect(display.name == "main")
    #expect(display.scope == "origin-mirror")
  }

  /// A local branch named exactly like a remote has no trailing slash, so it
  /// stays Local rather than being mistaken for a remote ref.
  @Test func rowDisplayTreatsBareRemoteNameAsLocal() {
    let display = BaseRefBranchMenu.rowDisplay(for: "origin", remoteNames: ["origin"])
    #expect(display.name == "origin")
    #expect(display.scope == "Local")
  }

  @Test func rowDisplayTagsLocalWhenNoRemotes() {
    let display = BaseRefBranchMenu.rowDisplay(for: "main", remoteNames: [])
    #expect(display.name == "main")
    #expect(display.scope == "Local")
  }
}
