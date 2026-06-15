import Foundation

nonisolated enum PullRequestMergeBlockingReason: Equatable, Hashable {
  case mergeConflicts
  case changesRequested
  case checksFailed(Int)
  case blocked
}

nonisolated struct PullRequestMergeReadiness: Equatable, Hashable {
  let blockingReason: PullRequestMergeBlockingReason?

  init(pullRequest: GithubPullRequest) {
    let mergeable = pullRequest.mergeable?.uppercased()
    let mergeStateStatus = pullRequest.mergeStateStatus?.uppercased()
    let reviewDecision = pullRequest.reviewDecision?.uppercased()
    let checks = pullRequest.statusCheckRollup?.checks ?? []
    let breakdown = PullRequestCheckBreakdown(checks: checks)

    if mergeable == "CONFLICTING" || mergeStateStatus == "DIRTY" {
      self.blockingReason = .mergeConflicts
      return
    }
    if reviewDecision == "CHANGES_REQUESTED" {
      self.blockingReason = .changesRequested
      return
    }
    if breakdown.failed > 0 {
      self.blockingReason = .checksFailed(breakdown.failed)
      return
    }

    if mergeable == "MERGEABLE" {
      self.blockingReason = nil
      return
    }

    self.blockingReason = .blocked
  }

  var isBlocking: Bool {
    blockingReason != nil
  }

  var isConflicting: Bool {
    blockingReason == .mergeConflicts
  }

  var label: String {
    switch blockingReason {
    case .none:
      return "Mergeable"
    case .mergeConflicts:
      return "Merge conflicts"
    case .changesRequested:
      return "Changes requested"
    case .checksFailed(let count):
      let checksLabel = count == 1 ? "check" : "checks"
      return "\(count) \(checksLabel) failed"
    case .blocked:
      return "Blocked"
    }
  }
}
