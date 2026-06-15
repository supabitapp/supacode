import Testing

@testable import supacode

@MainActor
struct SidebarHighlightOrderingTests {
  private func candidate(
    _ id: String,
    branch: String,
    classification: SidebarActiveClassification? = nil
  ) -> SidebarHighlightOrdering.Candidate {
    .init(id: id, branchName: branch, classification: classification)
  }

  @Test func keepsUnclassifiedAtBottomAlphabetically() {
    let ids = SidebarHighlightOrdering.orderedRowIDs(
      candidates: [
        candidate("c", branch: "charlie"),
        candidate("a", branch: "alpha"),
        candidate("b", branch: "bravo", classification: .running),
      ]
    )
    // Classified row first (priority 10), then unclassified rows alphabetically.
    #expect(ids == ["b", "a", "c"])
  }

  @Test func priorityOrdersAcrossClassifications() {
    let ids = SidebarHighlightOrdering.orderedRowIDs(
      candidates: [
        candidate("running", branch: "running", classification: .running),
        candidate("unreadAwaiting", branch: "unread-awaiting", classification: .unreadAwaiting),
        candidate("agent", branch: "agent", classification: .agent),
        candidate("unreadAwaitingRunning", branch: "top", classification: .unreadAwaitingRunning),
      ]
    )
    #expect(ids == ["unreadAwaitingRunning", "unreadAwaiting", "agent", "running"])
  }

  @Test func alphabeticalTieBreakIsLocaleInsensitive() {
    // Same priority bucket; tie-break must be locale-insensitive alphabetical
    // on branch name so "Bravo" and "bravo" don't flip when the user has
    // different system locales.
    let ids = SidebarHighlightOrdering.orderedRowIDs(
      candidates: [
        candidate("z", branch: "Zulu", classification: .running),
        candidate("a", branch: "alpha", classification: .running),
        candidate("b", branch: "Bravo", classification: .running),
      ]
    )
    #expect(ids == ["a", "b", "z"])
  }

  @Test func emptyCandidatesYieldEmptyOrder() {
    #expect(SidebarHighlightOrdering.orderedRowIDs(candidates: []) == [])
  }
}
