import Foundation

/// GitLab REST merge request object, decoded from `glab api` output. Only the
/// fields the summary tier consumes; everything else is dropped tolerantly.
nonisolated struct GitLabMergeRequest: Decodable, Equatable {
  let iid: Int
  let title: String
  let state: PullRequestState
  let draft: Bool?
  let webUrl: String
  let sourceBranch: String?
  let targetBranch: String?
  let updatedAt: Date?
  let mergedAt: Date?
  let author: Author?

  nonisolated struct Author: Decodable, Equatable {
    let username: String
  }

  private enum CodingKeys: String, CodingKey {
    case iid
    case title
    case state
    case draft
    case webUrl = "web_url"
    case sourceBranch = "source_branch"
    case targetBranch = "target_branch"
    case updatedAt = "updated_at"
    case mergedAt = "merged_at"
    case author
  }

  var pullRequest: ForgePullRequest {
    ForgePullRequest(
      number: iid,
      title: title,
      state: state,
      additions: nil,
      deletions: nil,
      isDraft: draft ?? false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: updatedAt,
      mergedAt: mergedAt,
      url: webUrl,
      headRefName: sourceBranch,
      baseRefName: targetBranch,
      commitsCount: nil,
      authorLogin: author?.username,
      statusCheckRollup: nil,
      mergeQueueEntry: nil
    )
  }
}

extension GitLabMergeRequest {
  /// Branch-to-proposal matching over one page of merge requests, using the
  /// shared tie-break: open beats merged beats the rest, then recency, then
  /// the highest iid.
  nonisolated static func pullRequestsByBranch(
    _ mergeRequests: [GitLabMergeRequest],
    branches: [String]
  ) -> [String: ForgePullRequest] {
    var results: [String: ForgePullRequest] = [:]
    for branch in branches {
      let candidates = mergeRequests.filter { $0.sourceBranch == branch }
      guard
        let best = candidates.max(by: { left, right in
          if left.stateRank != right.stateRank {
            return left.stateRank < right.stateRank
          }
          let leftDate = left.updatedAt ?? .distantPast
          let rightDate = right.updatedAt ?? .distantPast
          if leftDate != rightDate {
            return leftDate < rightDate
          }
          return left.iid < right.iid
        })
      else { continue }
      results[branch] = best.pullRequest
    }
    return results
  }

  nonisolated private var stateRank: Int {
    switch state {
    case .open: 2
    case .merged: 1
    case .closed, .unknown: 0
    }
  }
}

/// Minimal parse of glab's `config.yml` for the authenticated host list. The
/// file is small and stable; a YAML dependency is not worth carrying for it.
nonisolated enum GitLabConfigHosts {
  static func parse(configYAML: String) -> Set<String> {
    var hosts = Set<String>()
    var inHostsSection = false
    for rawLine in configYAML.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      if line.hasPrefix("hosts:") {
        inHostsSection = true
        continue
      }
      guard inHostsSection else { continue }
      // A non-indented line ends the hosts section.
      if !line.hasPrefix(" "), !line.trimmingCharacters(in: .whitespaces).isEmpty {
        break
      }
      // Host entries sit one indent level deep, as `  gitlab.com:`.
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasSuffix(":"), !trimmed.hasPrefix("#") else { continue }
      let indentWidth = line.prefix(while: { $0 == " " }).count
      guard indentWidth == 2 || indentWidth == 4 else { continue }
      let host = String(trimmed.dropLast())
      if indentWidth == 2, !host.isEmpty {
        hosts.insert(host.lowercased())
      }
    }
    return hosts
  }

  static func configFileURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    if let configDirectory = environment["GLAB_CONFIG_DIR"], !configDirectory.isEmpty {
      return URL(fileURLWithPath: configDirectory).appending(path: "config.yml")
    }
    guard let home = environment["HOME"], !home.isEmpty else { return nil }
    return URL(fileURLWithPath: home).appending(path: ".config/glab-cli/config.yml")
  }
}
