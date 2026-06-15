import Foundation

nonisolated struct PullRequestMergeQueueStatus: Equatable, Hashable {
  enum State: Equatable, Hashable {
    case queued
    case awaitingChecks
    case mergeable
    case unmergeable
    case locked
    case unknown

    init(rawValue: String?) {
      switch rawValue?.uppercased() {
      case "QUEUED": self = .queued
      case "AWAITING_CHECKS": self = .awaitingChecks
      case "MERGEABLE": self = .mergeable
      case "UNMERGEABLE": self = .unmergeable
      case "LOCKED": self = .locked
      default: self = .unknown
      }
    }
  }

  let position: Int
  let estimatedTimeToMerge: Int?
  let state: State

  // Only an open, non-draft PR with a live queue entry is in the merge queue, so a stale entry
  // on a merged / draft PR never surfaces as queued across the sidebar and popover.
  init?(pullRequest: GithubPullRequest) {
    guard pullRequest.state.uppercased() == "OPEN",
      !pullRequest.isDraft,
      let entry = pullRequest.mergeQueueEntry
    else { return nil }
    self.position = entry.displayPosition
    self.estimatedTimeToMerge = entry.estimatedTimeToMerge
    self.state = State(rawValue: entry.state)
  }

  var summary: String {
    switch state {
    case .awaitingChecks:
      return "Awaiting checks in merge queue"
    case .unmergeable:
      return "Cannot merge from queue"
    case .locked:
      return "Merge queue locked"
    case .queued, .mergeable, .unknown:
      return "In merge queue"
    }
  }

  var positionLabel: String {
    "Position \(position)"
  }

  var estimatedTimeLabel: String? {
    guard let estimatedTimeToMerge, estimatedTimeToMerge > 0 else { return nil }
    guard estimatedTimeToMerge >= 60 else { return "<1 min left" }
    let formatted = Duration.seconds(estimatedTimeToMerge)
      .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    return "~\(formatted) left"
  }

  var detail: String? {
    let parts = [positionLabel, estimatedTimeLabel].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
