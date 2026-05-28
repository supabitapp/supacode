import Foundation

nonisolated struct GitLabMergeRequest: Equatable, Hashable, Sendable {
  let iid: Int
  let title: String
  let state: GitLabMergeRequestState
  let additions: Int
  let deletions: Int
  let isDraft: Bool
  let updatedAt: Date?
  let url: String
  let sourceBranch: String?
  let targetBranch: String?
  let authorUsername: String?
  let pipelineStatus: GitLabPipelineStatus?
}

nonisolated enum GitLabMergeRequestState: String, Equatable, Hashable, Sendable, Codable {
  case opened
  case closed
  case merged
  case locked
  case unknown

  init(rawGraphQL: String) {
    switch rawGraphQL.lowercased() {
    case "opened": self = .opened
    case "closed": self = .closed
    case "merged": self = .merged
    case "locked": self = .locked
    default: self = .unknown
    }
  }
}
