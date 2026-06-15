import Testing

@testable import tty7

@MainActor
struct PullRequestCheckBreakdownTests {
  @Test func breakdownClassifiesChecksByStatusStateAndConclusion() {
    let checks = [
      GithubPullRequestStatusCheck(status: "IN_PROGRESS", conclusion: "SUCCESS", state: "SUCCESS"),
      GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: nil, state: "EXPECTED"),
      GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: nil, state: "PENDING"),
      GithubPullRequestStatusCheck(status: nil, conclusion: "SKIPPED", state: nil),
      GithubPullRequestStatusCheck(status: nil, conclusion: "SUCCESS", state: nil),
      GithubPullRequestStatusCheck(status: nil, conclusion: "FAILURE", state: nil),
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
      GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: nil, state: "UNKNOWN"),
      GithubPullRequestStatusCheck(status: nil, conclusion: "UNKNOWN", state: nil),
      GithubPullRequestStatusCheck(status: nil, conclusion: nil, state: nil),
    ]

    let breakdown = PullRequestCheckBreakdown(checks: checks)

    #expect(breakdown.inProgress == 3)
    #expect(breakdown.total == 3)
  }

  @Test func breakdownSummaryTextIncludesAllStatuses() {
    let checks = [
      GithubPullRequestStatusCheck(status: "IN_PROGRESS", conclusion: "SUCCESS", state: "SUCCESS"),
      GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: nil, state: "EXPECTED"),
      GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: nil, state: "PENDING"),
      GithubPullRequestStatusCheck(status: nil, conclusion: "SKIPPED", state: nil),
      GithubPullRequestStatusCheck(status: nil, conclusion: "SUCCESS", state: nil),
      GithubPullRequestStatusCheck(status: nil, conclusion: "FAILURE", state: nil),
    ]

    let breakdown = PullRequestCheckBreakdown(checks: checks)

    #expect(
      breakdown.summaryText
        == "1 failed, 2 in progress, 1 skipped, 1 expected, 1 successful"
    )
  }
}
