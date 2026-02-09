import Foundation

struct TaskRowModel: Identifiable, Hashable {
  let id: String
  let repositoryID: Repository.ID
  let name: String
  let agentSummary: String
  let variantCount: Int
  let isPending: Bool
  let isDeleting: Bool
}
