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

  @Test func prioritiesOrderedAsSpec() {
    // The bucket priority ordering is the user contract; lock it explicitly
    // so a future shuffle of the enum case order can't silently re-rank.
    let expected: [SidebarActiveClassification] = [
      .unreadAwaitingRunning, .unreadAwaiting, .unreadAgentRunning, .unreadAgent,
      .unreadRunning, .awaitingRunning, .awaiting, .agentRunning, .agent, .running,
    ]
    #expect(SidebarActiveClassification.allCases == expected)
  }
}
