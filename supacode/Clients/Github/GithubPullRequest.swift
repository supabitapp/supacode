import Foundation

nonisolated struct GithubPullRequest: Decodable, Equatable, Hashable {
  let number: Int
  let title: String
  let state: PullRequestState
  let additions: Int
  let deletions: Int
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
  let statusCheckRollup: GithubPullRequestStatusCheckRollup?
  let mergeQueueEntry: GithubMergeQueueEntry?
}
