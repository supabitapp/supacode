import Foundation

nonisolated enum PullRequestMergeBlockingReason: Equatable, Hashable {
  case mergeConflicts
  case changesRequested
  case checksFailed(Int)
  /// Forge-reported block outside the shared vocabulary, carrying the forge's
  /// own prose (e.g. GitLab's "Not approved").
  case other(String)
}

nonisolated struct PullRequestMergeReadiness: Equatable, Hashable {
  enum Assessment: Equatable, Hashable {
    case mergeable
    // The forge has not confirmed mergeability yet; "not yet", never a red block.
    case checking
    case blocked(PullRequestMergeBlockingReason)
  }

  let assessment: Assessment

  init(pullRequest: ForgePullRequest) {
    let mergeable = pullRequest.mergeable?.uppercased()
    let mergeStateStatus = pullRequest.mergeStateStatus?.uppercased()
    let reviewDecision = pullRequest.reviewDecision?.uppercased()
    let checks = pullRequest.statusCheckRollup?.checks ?? []
    let breakdown = PullRequestCheckBreakdown(checks: checks)

    if mergeable == "CONFLICTING" || mergeStateStatus == "DIRTY" {
      self.assessment = .blocked(.mergeConflicts)
      return
    }
    if reviewDecision == "CHANGES_REQUESTED" {
      self.assessment = .blocked(.changesRequested)
      return
    }
    if breakdown.failed > 0 {
      self.assessment = .blocked(.checksFailed(breakdown.failed))
      return
    }
    if let forgeBlockedReason = pullRequest.forgeBlockedReason {
      self.assessment = .blocked(.other(forgeBlockedReason))
      return
    }

    if mergeable == "MERGEABLE" {
      self.assessment = .mergeable
      return
    }

    self.assessment = .checking
  }

  /// Only a confirmed-mergeable pull request may be merged.
  var canMergeNow: Bool {
    assessment == .mergeable
  }

  var blockingReason: PullRequestMergeBlockingReason? {
    guard case .blocked(let reason) = assessment else { return nil }
    return reason
  }

  var isConflicting: Bool {
    assessment == .blocked(.mergeConflicts)
  }

  var label: String {
    switch assessment {
    case .mergeable:
      return "Mergeable"
    case .checking:
      return "Checking"
    case .blocked(.mergeConflicts):
      return "Merge conflicts"
    case .blocked(.changesRequested):
      return "Changes requested"
    case .blocked(.checksFailed(let count)):
      let checksLabel = count == 1 ? "check" : "checks"
      return "\(count) \(checksLabel) failed"
    case .blocked(.other(let reason)):
      return reason
    }
  }
}
