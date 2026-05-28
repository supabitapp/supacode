import Foundation

// Forge-tagged pull/merge request. Views and reducers that don't care which forge the request came
// from read the shared projection (number, title, isDraft, ...). Views that need forge-specific
// fields pull out the underlying case via `.github` / `.gitlab`.
nonisolated enum ForgePullRequest: Equatable, Hashable, Sendable {
  case github(GithubPullRequest)
  case gitlab(GitLabMergeRequest)
}

extension ForgePullRequest {
  var forge: Forge {
    switch self {
    case .github: return .github
    case .gitlab: return .gitlab
    }
  }

  // GitHub: PR number. GitLab: MR iid.
  var number: Int {
    switch self {
    case .github(let pr): return pr.number
    case .gitlab(let mr): return mr.iid
    }
  }

  var title: String {
    switch self {
    case .github(let pr): return pr.title
    case .gitlab(let mr): return mr.title
    }
  }

  var url: String {
    switch self {
    case .github(let pr): return pr.url
    case .gitlab(let mr): return mr.url
    }
  }

  var isDraft: Bool {
    switch self {
    case .github(let pr): return pr.isDraft
    case .gitlab(let mr): return mr.isDraft
    }
  }

  var additions: Int {
    switch self {
    case .github(let pr): return pr.additions
    case .gitlab(let mr): return mr.additions
    }
  }

  var deletions: Int {
    switch self {
    case .github(let pr): return pr.deletions
    case .gitlab(let mr): return mr.deletions
    }
  }

  var updatedAt: Date? {
    switch self {
    case .github(let pr): return pr.updatedAt
    case .gitlab(let mr): return mr.updatedAt
    }
  }

  var headRefName: String? {
    switch self {
    case .github(let pr): return pr.headRefName
    case .gitlab(let mr): return mr.sourceBranch
    }
  }

  var baseRefName: String? {
    switch self {
    case .github(let pr): return pr.baseRefName
    case .gitlab(let mr): return mr.targetBranch
    }
  }

  var authorLogin: String? {
    switch self {
    case .github(let pr): return pr.authorLogin
    case .gitlab(let mr): return mr.authorUsername
    }
  }

  var isMerged: Bool {
    switch self {
    case .github(let pr): return pr.state == "MERGED"
    case .gitlab(let mr): return mr.state == .merged
    }
  }

  var isOpen: Bool {
    switch self {
    case .github(let pr): return pr.state == "OPEN"
    case .gitlab(let mr): return mr.state == .opened
    }
  }

  // Uppercase state string compatible with the existing `PullRequestBadgeStyle.style(state:...)`
  // vocabulary ("OPEN" / "MERGED" / "CLOSED"). GitLab states are mapped to the nearest GitHub
  // equivalent so the badge color picker keeps working without per-forge branching.
  var displayStateBadge: String? {
    switch self {
    case .github(let pr):
      return pr.state.uppercased()
    case .gitlab(let mr):
      switch mr.state {
      case .opened: return "OPEN"
      case .merged: return "MERGED"
      case .closed, .locked: return "CLOSED"
      case .unknown: return nil
      }
    }
  }

  var github: GithubPullRequest? {
    if case .github(let pr) = self { return pr }
    return nil
  }

  var gitlab: GitLabMergeRequest? {
    if case .gitlab(let mr) = self { return mr }
    return nil
  }
}
