import Foundation

nonisolated struct ForgePullRequest: Equatable, Hashable {
  let number: Int
  let title: String
  let state: PullRequestState
  let additions: Int?
  let deletions: Int?
  let isDraft: Bool
  let reviewDecision: String?
  let mergeable: String?
  let mergeStateStatus: String?
  let updatedAt: Date?
  let mergedAt: Date?
  let url: String
  let headRefName: String?
  let baseRefName: String?
  let commitsCount: Int?
  let authorLogin: String?
  let statusCheckRollup: ForgePullRequestStatusCheckRollup?
  let mergeQueueEntry: ForgeMergeQueueEntry?
  /// Forge-reported merge block outside the shared vocabulary (detail tier
  /// only); rendered verbatim. Never set by the GitHub adapter.
  let forgeBlockedReason: String?

  init(
    number: Int,
    title: String,
    state: PullRequestState,
    additions: Int?,
    deletions: Int?,
    isDraft: Bool,
    reviewDecision: String?,
    mergeable: String?,
    mergeStateStatus: String?,
    updatedAt: Date?,
    mergedAt: Date?,
    url: String,
    headRefName: String?,
    baseRefName: String?,
    commitsCount: Int?,
    authorLogin: String?,
    statusCheckRollup: ForgePullRequestStatusCheckRollup?,
    mergeQueueEntry: ForgeMergeQueueEntry?,
    forgeBlockedReason: String? = nil
  ) {
    self.number = number
    self.title = title
    self.state = state
    self.additions = additions
    self.deletions = deletions
    self.isDraft = isDraft
    self.reviewDecision = reviewDecision
    self.mergeable = mergeable
    self.mergeStateStatus = mergeStateStatus
    self.updatedAt = updatedAt
    self.mergedAt = mergedAt
    self.url = url
    self.headRefName = headRefName
    self.baseRefName = baseRefName
    self.commitsCount = commitsCount
    self.authorLogin = authorLogin
    self.statusCheckRollup = statusCheckRollup
    self.mergeQueueEntry = mergeQueueEntry
    self.forgeBlockedReason = forgeBlockedReason
  }
}
