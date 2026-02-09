import Foundation

struct PendingTask: Identifiable, Hashable {
  let id: String
  let repositoryID: Repository.ID
  let name: String
}
