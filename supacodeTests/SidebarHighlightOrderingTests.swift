import Testing

@testable import supacode

@MainActor
struct SidebarHighlightOrderingTests {
  private func candidate(
    _ id: String,
    branch: String,
    classification: SidebarActiveClassification? = nil
  ) -> SidebarHighlightOrdering.Candidate {
    .init(id: WorktreeID(id), branchName: branch, classification: classification)
  }

  @Test func activeDropsUnclassifiedRows() {
    let ids = SidebarHighlightOrdering.orderedRowIDs(
      forPinned: false,
      candidates: [
        candidate("a", branch: "alpha"),
        candidate("b", branch: "beta", classification: .running),
      ]
    )
    #expect(ids == ["b"])
  }

  @Test func pinnedKeepsUnclassifiedAtBottomAlphabetically() {
    let ids = SidebarHighlightOrdering.orderedRowIDs(
      forPinned: true,
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
      forPinned: false,
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
      forPinned: false,
      candidates: [
        candidate("z", branch: "Zulu", classification: .running),
        candidate("a", branch: "alpha", classification: .running),
        candidate("b", branch: "Bravo", classification: .running),
      ]
    )
    #expect(ids == ["a", "b", "z"])
  }

  @Test func pinnedAndActiveDoNotDuplicate() {
    // Active section drops rows that are already in Pinned, so the same
    // worktree never renders twice in the highlight region. The aggregator
    // performs the dedup before calling this helper (via the `excluding`
    // set on the view side); locking the pure helper's behavior here.
    let candidates: [SidebarHighlightOrdering.Candidate] = [
      candidate("shared", branch: "shared", classification: .running),
      candidate("active-only", branch: "active", classification: .agent),
    ]
    let activeIDs = SidebarHighlightOrdering.orderedRowIDs(
      forPinned: false,
      candidates: candidates.filter { $0.id != "shared" }
    )
    #expect(activeIDs == ["active-only"])
  }

  @Test func emptyCandidatesYieldEmptyOrder() {
    #expect(SidebarHighlightOrdering.orderedRowIDs(forPinned: true, candidates: []) == [])
    #expect(SidebarHighlightOrdering.orderedRowIDs(forPinned: false, candidates: []) == [])
  }
}
