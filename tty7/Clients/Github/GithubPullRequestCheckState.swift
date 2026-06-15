import Foundation

nonisolated enum GithubPullRequestCheckState: Equatable {
  case success
  case failure
  case inProgress
  case expected
  case skipped
}
