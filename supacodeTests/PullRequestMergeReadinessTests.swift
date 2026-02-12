import Testing

@testable import supacode

@MainActor
struct PullRequestMergeReadinessTests {
  @Test func mergeReadinessUsesConflictReasonFirst() {
    let pullRequest = makePullRequest(
      reviewDecision: "CHANGES_REQUESTED",
      mergeable: "CONFLICTING",
      mergeStateStatus: "DIRTY"
    )

    let readiness = PullRequestMergeReadiness(pullRequest: pullRequest)

    #expect(readiness.blockingReason == .mergeConflicts)
    #expect(readiness.isBlocking)
    #expect(readiness.label == "Merge conflicts")
    #expect(readiness.isConflicting)
  }

  @Test func mergeReadinessUsesChangesRequestedWhenNoConflict() {
    let pullRequest = makePullRequest(
      reviewDecision: "CHANGES_REQUESTED",
      mergeable: "MERGEABLE",
      mergeStateStatus: "CLEAN"
    )

    let readiness = PullRequestMergeReadiness(pullRequest: pullRequest)

    #expect(readiness.blockingReason == .changesRequested)
    #expect(readiness.label == "Changes requested")
  }

  @Test func mergeReadinessUsesFailedChecksCountWhenPresent() {
    let pullRequest = makePullRequest(
      mergeable: "MERGEABLE",
      mergeStateStatus: "CLEAN",
      checks: [
        GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: "FAILURE", state: nil),
        GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: "FAILURE", state: nil),
      ]
    )

    let readiness = PullRequestMergeReadiness(pullRequest: pullRequest)

    #expect(readiness.blockingReason == .checksFailed(2))
    #expect(readiness.label == "2 checks failed")
  }

  @Test func mergeReadinessIsMergeableWhenMergeable() {
    let pullRequest = makePullRequest(
      mergeable: "MERGEABLE",
      mergeStateStatus: "BEHIND"
    )

    let readiness = PullRequestMergeReadiness(pullRequest: pullRequest)

    #expect(readiness.blockingReason == nil)
    #expect(!readiness.isBlocking)
    #expect(readiness.label == "Mergeable")
  }

  @Test func mergeReadinessFallsBackToBlockedForOtherStates() {
    let pullRequest = makePullRequest(
      mergeable: "UNKNOWN",
      mergeStateStatus: "BEHIND"
    )

    let readiness = PullRequestMergeReadiness(pullRequest: pullRequest)

    #expect(readiness.blockingReason == .blocked)
    #expect(readiness.label == "Blocked")
  }
}

private func makePullRequest(
  reviewDecision: String? = nil,
  mergeable: String? = nil,
  mergeStateStatus: String? = nil,
  checks: [GithubPullRequestStatusCheck] = []
) -> GithubPullRequest {
  GithubPullRequest(
    number: 1,
    title: "PR",
    state: "OPEN",
    additions: 0,
    deletions: 0,
    isDraft: false,
    reviewDecision: reviewDecision,
    mergeable: mergeable,
    mergeStateStatus: mergeStateStatus,
    updatedAt: nil,
    url: "https://example.com/pull/1",
    headRefName: "feature",
    baseRefName: "main",
    commitsCount: 1,
    authorLogin: "khoi",
    statusCheckRollup: checks.isEmpty ? nil : GithubPullRequestStatusCheckRollup(checks: checks)
  )
}
