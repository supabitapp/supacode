import Foundation
import Testing

@testable import supacode

struct PullRequestReviewDecisionTests {
  @Test func parsesForgeDecisionCaseInsensitively() {
    #expect(PullRequestReviewDecision(forgeDecision: "APPROVED") == .approved)
    #expect(PullRequestReviewDecision(forgeDecision: "approved") == .approved)
    #expect(PullRequestReviewDecision(forgeDecision: "CHANGES_REQUESTED") == .changesRequested)
    #expect(PullRequestReviewDecision(forgeDecision: "review_required") == .reviewRequired)
  }

  @Test func unknownOrMissingDecisionIsNil() {
    #expect(PullRequestReviewDecision(forgeDecision: nil) == nil)
    #expect(PullRequestReviewDecision(forgeDecision: "") == nil)
    #expect(PullRequestReviewDecision(forgeDecision: "COMMENTED") == nil)
  }

  @Test func latestReviewsPreferChangesRequestedOverApproval() {
    #expect(PullRequestReviewDecision(latestReviewStates: ["APPROVED", "CHANGES_REQUESTED"]) == .changesRequested)
    #expect(PullRequestReviewDecision(latestReviewStates: ["APPROVED", "COMMENTED"]) == .approved)
    #expect(PullRequestReviewDecision(latestReviewStates: ["COMMENTED", "DISMISSED"]) == nil)
    #expect(PullRequestReviewDecision(latestReviewStates: []) == nil)
  }

  @Test func reviewStatusOnlySurfacesForOpenNonDraftProposals() {
    #expect(makePullRequest(reviewDecision: "APPROVED").reviewStatus == .approved)
    #expect(makePullRequest(isDraft: true, reviewDecision: "REVIEW_REQUIRED").reviewStatus == nil)
    #expect(makePullRequest(state: .merged, reviewDecision: "APPROVED").reviewStatus == nil)
    #expect(makePullRequest(state: .closed, reviewDecision: "CHANGES_REQUESTED").reviewStatus == nil)
    #expect(makePullRequest().reviewStatus == nil)
  }

  @Test func forgeDecisionWinsOverLatestReviewsFallback() {
    let pullRequest = makePullRequest(reviewDecision: "REVIEW_REQUIRED", fallbackReviewDecision: .approved)
    #expect(pullRequest.reviewStatus == .reviewRequired)
    #expect(makePullRequest(fallbackReviewDecision: .approved).reviewStatus == .approved)
  }

  @Test func forgeDecisionWinsEvenWhenFallbackIsStricter() {
    let pullRequest = makePullRequest(reviewDecision: "APPROVED", fallbackReviewDecision: .changesRequested)
    #expect(pullRequest.reviewStatus == .approved)
  }

  @Test func fallbackChangesRequestBeatsAPendingReviewRequirement() {
    // GitLab's detail tier reports not_approved while the sweep saw a reviewer's changes request.
    let pullRequest = makePullRequest(reviewDecision: "REVIEW_REQUIRED", fallbackReviewDecision: .changesRequested)
    #expect(pullRequest.reviewStatus == .changesRequested)
    #expect(PullRequestMergeReadiness(pullRequest: pullRequest).blockingReason != .changesRequested)
  }

  @Test func unrecognizedForgeDecisionSuppressesTheFallback() {
    let pullRequest = makePullRequest(reviewDecision: "SOMETHING_NEW", fallbackReviewDecision: .approved)
    #expect(pullRequest.reviewStatus == nil)
  }

  @Test func onlyChangesRequestedBlocksMerge() {
    let lowercased = makePullRequest(reviewDecision: "changes_requested", mergeable: "MERGEABLE")
    #expect(PullRequestMergeReadiness(pullRequest: lowercased).assessment == .blocked(.changesRequested))
    for decision in ["APPROVED", "REVIEW_REQUIRED"] {
      let pullRequest = makePullRequest(reviewDecision: decision, mergeable: "MERGEABLE")
      #expect(PullRequestMergeReadiness(pullRequest: pullRequest).assessment == .mergeable)
    }
  }

  @Test func latestReviewsFallbackNeverBlocksMerge() {
    let pullRequest = makePullRequest(mergeable: "MERGEABLE", fallbackReviewDecision: .changesRequested)
    #expect(pullRequest.reviewStatus == .changesRequested)
    #expect(PullRequestMergeReadiness(pullRequest: pullRequest).assessment == .mergeable)
  }

  @Test func detailEnrichmentKeepsFallbackReviewDecision() {
    let pullRequest = makePullRequest(fallbackReviewDecision: .approved)
    let enriched = pullRequest.applying(ForgePullRequestDetail(reviewDecision: "CHANGES_REQUESTED"))
    #expect(enriched.fallbackReviewDecision == .approved)
    #expect(enriched.reviewStatus == .changesRequested)
  }

  @Test func githubFallsBackToLatestReviewsWhenDecisionIsNull() throws {
    let prs = try decodeGithubNode(
      reviewDecision: "null",
      extraFields: #""latestOpinionatedReviews": { "nodes": [{ "state": "APPROVED" }, { "state": "COMMENTED" }] },"#
    )
    #expect(prs["feature"]?.reviewDecision == nil)
    #expect(prs["feature"]?.reviewStatus == .approved)
  }

  @Test func githubToleratesNullReviewNodes() throws {
    let withNullNode = try decodeGithubNode(
      reviewDecision: "null",
      extraFields: #""latestOpinionatedReviews": { "nodes": [null, { "state": "APPROVED" }] },"#
    )
    #expect(withNullNode["feature"]?.reviewStatus == .approved)
    let withNullList = try decodeGithubNode(
      reviewDecision: "null",
      extraFields: #""latestOpinionatedReviews": { "nodes": null },"#
    )
    #expect(withNullList["feature"]?.number == 3)
    #expect(withNullList["feature"]?.reviewStatus == nil)
    let withNullConnection = try decodeGithubNode(
      reviewDecision: "null", extraFields: #""latestOpinionatedReviews": null,"#)
    #expect(withNullConnection["feature"]?.reviewStatus == nil)
  }

  @Test func githubUsesAggregateDecisionAndToleratesMissingReviews() throws {
    let prs = try decodeGithubNode(reviewDecision: #""CHANGES_REQUESTED""#, extraFields: "")
    #expect(prs["feature"]?.fallbackReviewDecision == nil)
    #expect(prs["feature"]?.reviewStatus == .changesRequested)
  }

  @Test func gitlabNotApprovedMapsToReviewRequiredAndStillBlocks() {
    let pullRequest = makeGitLabPullRequest(detailedMergeStatus: "not_approved")
    #expect(pullRequest.reviewStatus == .reviewRequired)
    #expect(PullRequestMergeReadiness(pullRequest: pullRequest).assessment == .blocked(.other("Not approved")))
  }

  @Test func gitlabNotApprovedWithConflictsKeepsConflictBlock() {
    let pullRequest = makeGitLabPullRequest(detailedMergeStatus: "not_approved", hasConflicts: true)
    #expect(pullRequest.reviewStatus == .reviewRequired)
    #expect(PullRequestMergeReadiness(pullRequest: pullRequest).isConflicting)
  }

  @Test func gitlabRequestedChangesMapsToChangesRequested() {
    #expect(makeGitLabPullRequest(detailedMergeStatus: "requested_changes").reviewStatus == .changesRequested)
    #expect(makeGitLabPullRequest(detailedMergeStatus: "NOT_APPROVED").reviewStatus == .reviewRequired)
    #expect(makeGitLabPullRequest(detailedMergeStatus: "mergeable").reviewStatus == nil)
  }

  @Test func gitlabSweepNodeMapsApprovalState() {
    func decision(
      _ status: String?,
      approved: Bool?,
      approvers: Int,
      reviewStates: [String?] = [],
      hasMoreReviewers: Bool = false
    ) -> PullRequestReviewDecision? {
      let nodes = (0..<approvers).map { _ in GitLabSweepEnrichments.Approver(id: "1") }
      var reviewers: [GitLabSweepEnrichments.Reviewer?] = []
      for state in reviewStates {
        reviewers.append(GitLabSweepEnrichments.Reviewer(mergeRequestInteraction: .init(reviewState: state)))
      }
      return GitLabSweepEnrichments.Node(
        iid: "1",
        headPipeline: nil,
        approved: approved,
        approvedBy: GitLabSweepEnrichments.Approvers(nodes: nodes),
        detailedMergeStatus: status,
        reviewers: GitLabSweepEnrichments.Reviewers(pageInfo: .init(hasNextPage: hasMoreReviewers), nodes: reviewers)
      ).reviewDecision
    }
    #expect(decision("REQUESTED_CHANGES", approved: true, approvers: 1) == .changesRequested)
    #expect(decision("NOT_APPROVED", approved: false, approvers: 0) == .reviewRequired)
    #expect(decision("CI_STILL_RUNNING", approved: false, approvers: 1) == .reviewRequired)
    #expect(decision("MERGEABLE", approved: true, approvers: 1) == .approved)
    // A redacted reviewer state or a truncated reviewer list never reads as approved.
    #expect(decision("MERGEABLE", approved: true, approvers: 1, reviewStates: ["APPROVED", nil]) == nil)
    #expect(decision("MERGEABLE", approved: true, approvers: 1, hasMoreReviewers: true) == nil)
    // A changes request hidden behind another dominant merge check still wins over an approval.
    let hidden = decision(
      "DISCUSSIONS_NOT_RESOLVED", approved: true, approvers: 1, reviewStates: ["APPROVED", "requested_changes"])
    #expect(hidden == .changesRequested)
    // No approver and no approval rule (CE) is no verdict, not review required.
    #expect(decision("MERGEABLE", approved: false, approvers: 0) == nil)
    #expect(decision(nil, approved: nil, approvers: 0) == nil)
  }

  @Test func gitlabDetailDecisionWinsOverTheSweepVerdict() {
    var pullRequest = makePullRequest()
    pullRequest.fallbackReviewDecision = .approved
    let enriched = pullRequest.applying(ForgePullRequestDetail(reviewDecision: "CHANGES_REQUESTED"))
    #expect(enriched.reviewStatus == .changesRequested)
    #expect(pullRequest.reviewStatus == .approved)
  }

  @Test func enrichedReviewDecisionSurvivesOnlyAnUnchangedSummary() {
    let updatedAt = Date(timeIntervalSince1970: 1_000)
    let enriched = makePullRequest(reviewDecision: "REVIEW_REQUIRED", updatedAt: updatedAt)
    let unchanged = makePullRequest(updatedAt: updatedAt)
    let moved = makePullRequest(updatedAt: updatedAt.addingTimeInterval(60))

    let kept = SidebarItemFeature.preservingEnrichment(of: unchanged, over: enriched)
    let dropped = SidebarItemFeature.preservingEnrichment(of: moved, over: enriched)

    #expect(kept?.reviewStatus == .reviewRequired)
    #expect(dropped?.reviewStatus == nil)
  }

  @Test func preservedEnrichmentTakesTheFreshSummaryFallback() {
    let updatedAt = Date(timeIntervalSince1970: 1_000)
    let enriched = makePullRequest(updatedAt: updatedAt, fallbackReviewDecision: .approved)
    let fresh = makePullRequest(updatedAt: updatedAt, fallbackReviewDecision: .changesRequested)

    let merged = SidebarItemFeature.preservingEnrichment(of: fresh, over: enriched)

    #expect(merged?.reviewStatus == .changesRequested)
  }

  @Test func optionalFieldRejectionNamesOnlyTheRejectedFields() {
    func rejected(_ stderr: String) -> Set<GithubOptionalPullRequestField> {
      GithubOptionalPullRequestField.rejected(by: GithubCLIError.commandFailed(stderr))
    }
    #expect(rejected("Field 'mergeQueueEntry' doesn't exist on type 'PullRequest'") == [.mergeQueueEntry])
    #expect(
      rejected("Field 'latestOpinionatedReviews' doesn't accept argument 'writersOnly'") == [.latestOpinionatedReviews]
    )
    #expect(
      rejected("Field 'mergeQueueEntry' doesn't exist; Field 'latestOpinionatedReviews' doesn't exist")
        == [.mergeQueueEntry, .latestOpinionatedReviews]
    )
    #expect(rejected("Field 'author' doesn't exist on type 'PullRequest' near latestOpinionatedReviews").isEmpty)
    #expect(rejected("API rate limit exceeded for mergeQueueEntry").isEmpty)
    #expect(
      rejected("Field 'author' doesn't exist on type 'PullRequest'; Field 'mergeQueueEntry' is deprecated").isEmpty
    )
  }

  @Test func capabilitiesDeclareTheGitLabApprovalGap() {
    #expect(ForgeCapabilities.github.reviewStatusSupport == .full)
    #expect(ForgeCapabilities.gitlab.reviewStatusSupport == .partial)
  }

  private func decodeGithubNode(reviewDecision: String, extraFields: String) throws -> [String: ForgePullRequest] {
    let json = """
      {
        "data": {
          "repository": {
            "branch0": {
              "nodes": [
                {
                  "number": 3,
                  "title": "PR",
                  "state": "OPEN",
                  "additions": 1,
                  "deletions": 0,
                  "isDraft": false,
                  "reviewDecision": \(reviewDecision),
                  \(extraFields)
                  "updatedAt": "2025-01-02T00:00:00Z",
                  "url": "https://github.com/octo/repo/pull/3",
                  "headRefName": "feature",
                  "headRepository": {
                    "name": "repo",
                    "owner": { "login": "octo" }
                  }
                }
              ]
            }
          }
        }
      }
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(GithubGraphQLPullRequestResponse.self, from: Data(json.utf8))
    return response.pullRequestsByBranch(aliasMap: ["branch0": "feature"], owner: "octo", repo: "repo")
  }

  private func makeGitLabPullRequest(detailedMergeStatus: String, hasConflicts: Bool? = nil) -> ForgePullRequest {
    let detail = GitLabMergeRequestDetail(
      iid: 1,
      sha: nil,
      detailedMergeStatus: detailedMergeStatus,
      hasConflicts: hasConflicts,
      headPipeline: nil
    )
    return makePullRequest().applying(detail.pullRequestDetail)
  }

  private func makePullRequest(
    state: PullRequestState = .open,
    isDraft: Bool = false,
    reviewDecision: String? = nil,
    mergeable: String? = nil,
    updatedAt: Date? = nil,
    fallbackReviewDecision: PullRequestReviewDecision? = nil
  ) -> ForgePullRequest {
    ForgePullRequest(
      number: 1,
      title: "PR",
      state: state,
      additions: 0,
      deletions: 0,
      isDraft: isDraft,
      reviewDecision: reviewDecision,
      mergeable: mergeable,
      mergeStateStatus: nil,
      updatedAt: updatedAt,
      mergedAt: nil,
      url: "https://example.com/pull/1",
      headRefName: "feature",
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "dev",
      statusCheckRollup: nil,
      mergeQueueEntry: nil,
      fallbackReviewDecision: fallbackReviewDecision
    )
  }
}
