import Foundation

nonisolated struct ForgePullRequest: Decodable, Equatable, Hashable {
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
  var forgeBlockedReason: String?
}
