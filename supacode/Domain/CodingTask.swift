import Foundation
import IdentifiedCollections

struct CodingTask: Identifiable, Hashable, Sendable, Codable {
  let id: String
  let repositoryID: Repository.ID
  var name: String
  var initialPrompt: String
  var autoApprove: Bool
  var baseBranch: String
  var variants: IdentifiedArrayOf<TaskVariant>
  let createdAt: Date

  var isMultiAgent: Bool {
    variants.count > 1
  }
}
