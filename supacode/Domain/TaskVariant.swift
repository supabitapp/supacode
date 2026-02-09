import Foundation

struct TaskVariant: Identifiable, Hashable, Sendable, Codable {
  let id: String
  let taskID: String
  let agentID: String
  var name: String
  var branchName: String
  var worktreeID: Worktree.ID?
  var status: VariantStatus
  let createdAt: Date

  enum VariantStatus: String, Hashable, Sendable, Codable {
    case pending
    case creatingWorktree
    case ready
    case running
    case failed
  }
}
