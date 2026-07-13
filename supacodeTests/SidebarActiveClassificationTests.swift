import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct SidebarActiveClassificationTests {
  @Test func unreadAwaitingRunningTakesTopPriority() {
    let classification = SidebarActiveClassification.classify(
      hasUnread: true, hasAwaiting: true, hasAgent: true, hasRunning: true
    )
    #expect(classification == .unreadAwaitingRunning)
  }

  @Test func unreadAwaitingWithoutRunning() {
    let classification = SidebarActiveClassification.classify(
      hasUnread: true, hasAwaiting: true, hasAgent: true, hasRunning: false
    )
    #expect(classification == .unreadAwaiting)
  }

  @Test func unreadAgentRunningTakesPrecedenceOverUnreadAgent() {
    let classification = SidebarActiveClassification.classify(
      hasUnread: true, hasAwaiting: false, hasAgent: true, hasRunning: true
    )
    #expect(classification == .unreadAgentRunning)
  }

  @Test func unreadAgentWithoutRunning() {
    let classification = SidebarActiveClassification.classify(
      hasUnread: true, hasAwaiting: false, hasAgent: true, hasRunning: false
    )
    #expect(classification == .unreadAgent)
  }

  @Test func unreadRunningWithNoAgent() {
    let classification = SidebarActiveClassification.classify(
      hasUnread: true, hasAwaiting: false, hasAgent: false, hasRunning: true
    )
    #expect(classification == .unreadRunning)
  }

  @Test func awaitingRunningWithoutUnread() {
    let classification = SidebarActiveClassification.classify(
      hasUnread: false, hasAwaiting: true, hasAgent: true, hasRunning: true
    )
    #expect(classification == .awaitingRunning)
  }

  @Test func awaitingOnly() {
    let classification = SidebarActiveClassification.classify(
      hasUnread: false, hasAwaiting: true, hasAgent: true, hasRunning: false
    )
    #expect(classification == .awaiting)
  }

  @Test func agentRunningWithoutAwaiting() {
    let classification = SidebarActiveClassification.classify(
      hasUnread: false, hasAwaiting: false, hasAgent: true, hasRunning: true
    )
    #expect(classification == .agentRunning)
  }

  @Test func agentOnly() {
    let classification = SidebarActiveClassification.classify(
      hasUnread: false, hasAwaiting: false, hasAgent: true, hasRunning: false
    )
    #expect(classification == .agent)
  }
  @Test func ompBadgeClassifiesRowAsAgent() {
    var state = makeState(name: "omp")
    state.agents = [.init(agent: .omp, activity: .idle)]

    let classification = SidebarActiveClassification.classify(state)

    #expect(classification == .agent)
  }
  @Test func grokBadgeClassifiesRowAsAgent() {
    var state = makeState(name: "grok")
    state.agents = [.init(agent: .grok, activity: .idle)]

    let classification = SidebarActiveClassification.classify(state)

    #expect(classification == .agent)
  }

  @Test func runningOnly() {
    let classification = SidebarActiveClassification.classify(
      hasUnread: false, hasAwaiting: false, hasAgent: false, hasRunning: true
    )
    #expect(classification == .running)
  }

  @Test func idleRowDoesNotClassify() {
    let classification = SidebarActiveClassification.classify(
      hasUnread: false, hasAwaiting: false, hasAgent: false, hasRunning: false
    )
    #expect(classification == nil)
  }

  /// Regression: this combination used to fall through every case and return
  /// `nil`, which dropped the row from Active entirely.
  ///
  /// It is reachable. `agents` is emptied when the user turns off
  /// `agentPresenceBadgesEnabled`, which forces `hasAgent` and `hasAwaiting`
  /// false, while `hasUnseenNotifications` is a stored flag coupled to neither.
  /// So for a badge-disabled user, an agent that finished and left output behind
  /// never surfaced in the Active section at all.
  @Test func unreadWithNoAgentAndNoScriptStillClassifies() {
    let classification = SidebarActiveClassification.classify(
      hasUnread: true, hasAwaiting: false, hasAgent: false, hasRunning: false
    )
    #expect(classification == .unread)
  }

  /// The all-false row is now the only input that returns nil.
  @Test func idleIsTheOnlyUnclassifiedCombination() {
    var unclassified: [Int] = []
    for mask in 0..<16 {
      let classification = SidebarActiveClassification.classify(
        hasUnread: mask & 1 != 0,
        hasAwaiting: mask & 2 != 0,
        hasAgent: mask & 4 != 0,
        hasRunning: mask & 8 != 0
      )
      if classification == nil { unclassified.append(mask) }
    }
    #expect(unclassified == [0])
  }

  @Test func prioritiesOrderedAsSpec() {
    // The bucket priority ordering is the user contract; lock it explicitly
    // so a future shuffle of the enum case order can't silently re-rank.
    //
    // `.unread` is appended rather than slotted into the unread family (which
    // would have put it at rawValue 6) precisely so that adding it re-ranked
    // nothing: every case that existed before keeps its exact position, and the
    // new one sorts last among classified rows.
    let expected: [SidebarActiveClassification] = [
      .unreadAwaitingRunning, .unreadAwaiting, .unreadAgentRunning, .unreadAgent,
      .unreadRunning, .awaitingRunning, .awaiting, .agentRunning, .agent, .running,
      .unread,
    ]
    #expect(SidebarActiveClassification.allCases == expected)
  }
  private func makeState(name: String) -> SidebarItemFeature.State {
    SidebarItemFeature.State(
      id: SidebarItemID("/tmp/repo/wt-\(name)"),
      repositoryID: "/tmp/repo",
      kind: .gitWorktree,
      name: name,
      branchName: name,
      subtitle: nil,
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-\(name)"),
      repositoryAccent: nil,
      isMainWorktree: false,
      isPinned: false,
      hasMergedBadge: false
    )
  }
}
