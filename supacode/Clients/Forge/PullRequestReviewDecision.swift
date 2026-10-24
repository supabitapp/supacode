import Foundation

/// Normalized review verdict on a proposal, decoded case-insensitively from the
/// forge's `reviewDecision` vocabulary. Unrecognized values decode to nil.
nonisolated enum PullRequestReviewDecision: Hashable, Sendable {
  case approved
  case changesRequested
  case reviewRequired

  init?(forgeDecision: String?) {
    switch forgeDecision?.uppercased() {
    case "APPROVED": self = .approved
    case "CHANGES_REQUESTED": self = .changesRequested
    case "REVIEW_REQUIRED": self = .reviewRequired
    default: return nil
    }
  }

  /// Verdict from reviewers' latest review states when the forge has no aggregate;
  /// changes requested wins over approved, and it never yields review required.
  init?(latestReviewStates states: [String]) {
    var isApproved = false
    for state in states {
      switch state.uppercased() {
      case "CHANGES_REQUESTED":
        self = .changesRequested
        return
      case "APPROVED":
        isApproved = true
      default:
        continue
      }
    }
    guard isApproved else { return nil }
    self = .approved
  }

  var label: String {
    switch self {
    case .approved: "Approved"
    case .changesRequested: "Changes requested"
    case .reviewRequired: "Review required"
    }
  }
}

nonisolated extension ForgePullRequest {
  /// Review verdict worth surfacing: only for open, non-draft proposals. The fallback
  /// applies only to a missing decision, so an unrecognized one never reads as approved.
  var reviewStatus: PullRequestReviewDecision? {
    guard state == .open, !isDraft else { return nil }
    guard let reviewDecision else { return fallbackReviewDecision }
    let decision = PullRequestReviewDecision(forgeDecision: reviewDecision)
    // A known changes request is more specific than a pending review requirement.
    guard decision == .reviewRequired, fallbackReviewDecision == .changesRequested else { return decision }
    return .changesRequested
  }
}
