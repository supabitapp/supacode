import Foundation

nonisolated struct GithubWorkflowRun: Decodable, Equatable {
  let databaseId: Int
  let workflowName: String?
  let name: String?
  let displayTitle: String?
  let status: String
  let conclusion: String?
  let createdAt: Date?
  let updatedAt: Date?
}
