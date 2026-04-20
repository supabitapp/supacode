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
      // Tier 1 — PRs whose head ref lives in the queried repo.
      // The caller already resolved the query target, so an exact
      // head match is the most trustworthy signal.
      let upstreamCandidates = connection.nodes.filter { $0.matches(owner: normalizedOwner, repo: normalizedRepo) }
      // Tier 2 — fork PRs with an intact head repository. The
      // GraphQL query fetches by headRefName, so a fork PR like
      // "user:main → main" appears when querying for "main" even
      // though the local branch is the PR's target, not its source.
      // The `baseRefName != branch` guard excludes that case (nil
      // baseRefName is treated as unknown and excluded conservatively).
      let forkCandidates = connection.nodes.filter {
        $0.headRepository != nil
          && $0.baseRefName.map { $0.lowercased() != branch.lowercased() } ?? false
      }
      // Tier 3 — PRs whose head repository has been deleted
      // (GitHub returns `headRepository: null`). Common after a
      // fork PR is merged and the fork is removed; the PR itself
      // is still the correct match for the local branch. Only
      // consulted when Tiers 1 and 2 are empty so a deleted-fork
      // entry never outranks one with verifiable provenance.
      let deletedForkCandidates = connection.nodes.filter {
        $0.headRepository == nil
          && $0.baseRefName.map { $0.lowercased() != branch.lowercased() } ?? false
      }
      let candidates: [PullRequestNode]
      if !upstreamCandidates.isEmpty {
        candidates = upstreamCandidates
      } else if !forkCandidates.isEmpty {
        candidates = forkCandidates
      } else {
        candidates = deletedForkCandidates
      }
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
