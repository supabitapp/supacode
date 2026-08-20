import Foundation

nonisolated enum ForgePullRequestCheckState: Equatable {
  case success
  case failure
  case inProgress
  case expected
  case skipped
}
