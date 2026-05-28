import Foundation

nonisolated struct GitLabGraphQLMergeRequestResponse: Decodable, Sendable {
  let data: DataPayload

  nonisolated struct DataPayload: Decodable, Sendable {
    let project: ProjectPayload?
  }

  nonisolated struct ProjectPayload: Decodable, Sendable {
    let mergeRequests: MergeRequestsConnection
  }

  nonisolated struct MergeRequestsConnection: Decodable, Sendable {
    let nodes: [MergeRequestNode]
  }

  nonisolated struct MergeRequestNode: Decodable, Sendable {
    let iid: String
    let title: String
    let state: String
    let draft: Bool?
    let webUrl: String
    let updatedAt: Date?
    let sourceBranch: String?
    let targetBranch: String?
    let diffStatsSummary: DiffStatsSummary?
    let author: Author?
    let headPipeline: Pipeline?
  }

  nonisolated struct DiffStatsSummary: Decodable, Sendable {
    let additions: Int?
    let deletions: Int?
  }

  nonisolated struct Author: Decodable, Sendable {
    let username: String?
  }

  nonisolated struct Pipeline: Decodable, Sendable {
    let status: String?
  }

  // Group MRs by their source branch. If multiple MRs share a branch (rare but possible when a
  // closed/locked MR coexists with an open one), the most recently updated one wins. Caller has
  // already filtered to `state: opened` in v1, so ties are unlikely in practice.
  func mergeRequestsBySourceBranch() -> [String: GitLabMergeRequest] {
    guard let project = data.project else {
      return [:]
    }
    var byBranch: [String: GitLabMergeRequest] = [:]
    for node in project.mergeRequests.nodes {
      guard let branch = node.sourceBranch, !branch.isEmpty,
        let iid = Int(node.iid)
      else {
        continue
      }
      let mergeRequest = GitLabMergeRequest(
        iid: iid,
        title: node.title,
        state: GitLabMergeRequestState(rawGraphQL: node.state),
        additions: node.diffStatsSummary?.additions ?? 0,
        deletions: node.diffStatsSummary?.deletions ?? 0,
        isDraft: node.draft ?? false,
        updatedAt: node.updatedAt,
        url: node.webUrl,
        sourceBranch: node.sourceBranch,
        targetBranch: node.targetBranch,
        authorUsername: node.author?.username,
        pipelineStatus: node.headPipeline?.status.map(GitLabPipelineStatus.init(rawGraphQL:))
      )
      if let existing = byBranch[branch],
        let existingUpdated = existing.updatedAt,
        let nodeUpdated = node.updatedAt,
        existingUpdated > nodeUpdated
      {
        continue
      }
      byBranch[branch] = mergeRequest
    }
    return byBranch
  }
}
