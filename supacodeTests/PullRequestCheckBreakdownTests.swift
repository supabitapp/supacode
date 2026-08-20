import Testing

@testable import supacode

@MainActor
struct PullRequestCheckBreakdownTests {
  @Test func breakdownClassifiesChecksByStatusStateAndConclusion() {
    let checks = [
      ForgePullRequestStatusCheck(status: "IN_PROGRESS", conclusion: "SUCCESS", state: "SUCCESS"),
      ForgePullRequestStatusCheck(status: "COMPLETED", conclusion: nil, state: "EXPECTED"),
      ForgePullRequestStatusCheck(status: "COMPLETED", conclusion: nil, state: "PENDING"),
      ForgePullRequestStatusCheck(status: nil, conclusion: "SKIPPED", state: nil),
      ForgePullRequestStatusCheck(status: nil, conclusion: "SUCCESS", state: nil),
      ForgePullRequestStatusCheck(status: nil, conclusion: "FAILURE", state: nil),
    ]

    let breakdown = PullRequestCheckBreakdown(checks: checks)

    #expect(breakdown.inProgress == 2)
    #expect(breakdown.expected == 1)
    #expect(breakdown.skipped == 1)
    #expect(breakdown.passed == 1)
    #expect(breakdown.failed == 1)
    #expect(breakdown.total == 6)
  }

  @Test func breakdownDefaultsUnknownStatesToInProgress() {
    let checks = [
      ForgePullRequestStatusCheck(status: "COMPLETED", conclusion: nil, state: "UNKNOWN"),
      ForgePullRequestStatusCheck(status: nil, conclusion: "UNKNOWN", state: nil),
      ForgePullRequestStatusCheck(status: nil, conclusion: nil, state: nil),
    ]

    let breakdown = PullRequestCheckBreakdown(checks: checks)

    #expect(breakdown.inProgress == 3)
    #expect(breakdown.total == 3)
  }

  @Test func breakdownSummaryTextIncludesAllStatuses() {
    let checks = [
      ForgePullRequestStatusCheck(status: "IN_PROGRESS", conclusion: "SUCCESS", state: "SUCCESS"),
      ForgePullRequestStatusCheck(status: "COMPLETED", conclusion: nil, state: "EXPECTED"),
      ForgePullRequestStatusCheck(status: "COMPLETED", conclusion: nil, state: "PENDING"),
      ForgePullRequestStatusCheck(status: nil, conclusion: "SKIPPED", state: nil),
      ForgePullRequestStatusCheck(status: nil, conclusion: "SUCCESS", state: nil),
      ForgePullRequestStatusCheck(status: nil, conclusion: "FAILURE", state: nil),
    ]

    let breakdown = PullRequestCheckBreakdown(checks: checks)

    #expect(
      breakdown.summaryText
        == "1 failed, 2 in progress, 1 skipped, 1 expected, 1 successful"
    )
  }
}
