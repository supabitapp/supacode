import Foundation

// GitLab pipeline statuses returned by `Pipeline.status` (GraphQL `PipelineStatusEnum`).
// Mapped to a common visual vocabulary for the check ring UI.
nonisolated enum GitLabPipelineStatus: String, Equatable, Hashable, Sendable, Codable {
  case created
  case waitingForResource = "waiting_for_resource"
  case preparing
  case pending
  case running
  case success
  case failed
  case canceled
  case skipped
  case manual
  case scheduled
  case unknown

  init(rawGraphQL: String) {
    let normalized = rawGraphQL.lowercased()
    switch normalized {
    case "created": self = .created
    case "waiting_for_resource": self = .waitingForResource
    case "preparing": self = .preparing
    case "pending": self = .pending
    case "running": self = .running
    case "success": self = .success
    case "failed": self = .failed
    case "canceled", "cancelled": self = .canceled
    case "skipped": self = .skipped
    case "manual": self = .manual
    case "scheduled": self = .scheduled
    default: self = .unknown
    }
  }

  var isInProgress: Bool {
    switch self {
    case .running, .pending, .preparing, .waitingForResource, .created, .scheduled: return true
    case .success, .failed, .canceled, .skipped, .manual, .unknown: return false
    }
  }

  var isSuccess: Bool { self == .success }
  var isFailure: Bool { self == .failed }
}
