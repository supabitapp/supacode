import Foundation

nonisolated struct GithubGraphQLPullRequestResponse: Decodable {
  let data: DataContainer

  func pullRequestsByBranch(
    aliasMap: [String: String],
    owner: String,
    repo: String
  ) -> [String: GithubPullRequest] {
    let normalizedOwner = owner.lowercased()
    let normalizedRepo = repo.lowercased()
    var results: [String: GithubPullRequest] = [:]
    for (alias, connection) in data.repository.pullRequestsByAlias {
      guard let branch = aliasMap[alias] else {
        continue
      }
      let upstreamCandidates = connection.nodes.filter { $0.matches(owner: normalizedOwner, repo: normalizedRepo) }
      let candidates =
        upstreamCandidates.isEmpty
        ? connection.nodes.filter { $0.headRepository != nil }
        : upstreamCandidates
      if let node = candidates.max(by: { left, right in
        let leftRank = left.stateRank
        let rightRank = right.stateRank
        if leftRank != rightRank {
          return leftRank < rightRank
        }
        let leftDate = left.updatedAt ?? .distantPast
        let rightDate = right.updatedAt ?? .distantPast
        if leftDate != rightDate {
          return leftDate < rightDate
        }
        return left.number < right.number
      }) {
        results[branch] = node.pullRequest
      }
    }
    return results
  }

  nonisolated struct DataContainer: Decodable {
    let repository: Repository
  }

  nonisolated struct Repository: Decodable {
    let pullRequestsByAlias: [String: PullRequestConnection]

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: DynamicKey.self)
      var results: [String: PullRequestConnection] = [:]
      for key in container.allKeys {
        results[key.stringValue] = try container.decode(PullRequestConnection.self, forKey: key)
      }
      self.pullRequestsByAlias = results
    }
  }

  nonisolated struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
      self.stringValue = stringValue
      self.intValue = nil
    }

    init?(intValue: Int) {
      self.stringValue = "\(intValue)"
      self.intValue = intValue
    }
  }

  nonisolated struct PullRequestConnection: Decodable {
    let nodes: [PullRequestNode]
  }

  nonisolated struct PullRequestNode: Decodable {
    let number: Int
    let title: String
    let state: String
    let additions: Int
    let deletions: Int
    let isDraft: Bool
    let reviewDecision: String?
    let mergeable: String?
    let mergeStateStatus: String?
    let updatedAt: Date?
    let url: String
    let headRefName: String?
    let baseRefName: String?
    let commits: CommitConnection?
    let author: PullRequestAuthor?
    let statusCheckRollup: GithubPullRequestStatusCheckRollup?
    let headRepository: HeadRepository?

    var pullRequest: GithubPullRequest {
      GithubPullRequest(
        number: number,
        title: title,
        state: state,
        additions: additions,
        deletions: deletions,
        isDraft: isDraft,
        reviewDecision: reviewDecision,
        mergeable: mergeable,
        mergeStateStatus: mergeStateStatus,
        updatedAt: updatedAt,
        url: url,
        headRefName: headRefName,
        baseRefName: baseRefName,
        commitsCount: commits?.totalCount,
        authorLogin: author?.login,
        statusCheckRollup: statusCheckRollup
      )
    }

    var stateRank: Int {
      switch state.uppercased() {
      case "OPEN":
        return 2
      case "MERGED":
        return 1
      default:
        return 0
      }
    }

    func matches(owner: String, repo: String) -> Bool {
      guard let headRepository else {
        return false
      }
      return headRepository.owner.login.lowercased() == owner
        && headRepository.name.lowercased() == repo
    }
  }

  nonisolated struct CommitConnection: Decodable {
    let totalCount: Int
  }

  nonisolated struct PullRequestAuthor: Decodable {
    let login: String
  }

  nonisolated struct HeadRepository: Decodable {
    let name: String
    let owner: HeadRepositoryOwner
  }

  nonisolated struct HeadRepositoryOwner: Decodable {
    let login: String
  }
}
