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
  let projectID: Int?
  let sourceProjectID: Int?

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
    case projectID = "project_id"
    case sourceProjectID = "source_project_id"
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
      // A fork MR targeting this project can share a branch name (commonly
      // main). Same-project proposals win; fork-sourced ones remain a
      // fallback so the push-to-personal-fork workflow still matches.
      var sameProjectCandidates: [GitLabMergeRequest] = []
      var forkCandidates: [GitLabMergeRequest] = []
      for mergeRequest in mergeRequests {
        guard mergeRequest.sourceBranch == branch else { continue }
        if mergeRequest.matchesQueriedProject {
          sameProjectCandidates.append(mergeRequest)
        } else {
          forkCandidates.append(mergeRequest)
        }
      }
      let candidates = sameProjectCandidates.isEmpty ? forkCandidates : sameProjectCandidates
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

  nonisolated private var matchesQueriedProject: Bool {
    guard let projectID, let sourceProjectID else { return true }
    return projectID == sourceProjectID
  }

  nonisolated private var stateRank: Int {
    state.matchRank
  }
}

/// Minimal parse of glab's `config.yml` for the authenticated host list. The
/// file is small and stable; a YAML dependency is not worth carrying for it.
nonisolated enum GitLabConfigHosts {
  static func parse(configYAML: String) -> Set<String> {
    var hosts = Set<String>()
    var inHostsSection = false
    // glab's YAML writer has used both 2- and 4-space indents; the first
    // entry after `hosts:` fixes the host level, deeper lines are sub-keys.
    var hostIndentWidth: Int?
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
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasSuffix(":"), !trimmed.hasPrefix("#") else { continue }
      let indentWidth = line.prefix(while: { $0 == " " }).count
      if hostIndentWidth == nil {
        hostIndentWidth = indentWidth
      }
      guard indentWidth == hostIndentWidth else { continue }
      let host = String(trimmed.dropLast())
      if !host.isEmpty {
        hosts.insert(host.lowercased())
      }
    }
    return hosts
  }

  /// glab on macOS writes to `~/Library/Application Support/glab-cli` (Go's
  /// user config dir); older installs and XDG setups used `~/.config`-style
  /// paths, so probe the candidates and take the first that exists.
  static func configFileURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
  ) -> URL? {
    if let configDirectory = environment["GLAB_CONFIG_DIR"], !configDirectory.isEmpty {
      return URL(fileURLWithPath: configDirectory).appending(path: "config.yml")
    }
    guard let home = environment["HOME"], !home.isEmpty else { return nil }
    var candidates = [
      URL(fileURLWithPath: home).appending(path: "Library/Application Support/glab-cli/config.yml")
    ]
    if let xdgConfigHome = environment["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
      candidates.append(URL(fileURLWithPath: xdgConfigHome).appending(path: "glab-cli/config.yml"))
    }
    candidates.append(URL(fileURLWithPath: home).appending(path: ".config/glab-cli/config.yml"))
    return candidates.first(where: fileExists) ?? candidates.first
  }
}

/// Single merge request from the REST `projects/:id/merge_requests/:iid`
/// endpoint; only the detail-tier fields the app consumes.
nonisolated struct GitLabMergeRequestDetail: Decodable, Equatable {
  let iid: Int
  let detailedMergeStatus: String?
  let hasConflicts: Bool?
  let headPipeline: Pipeline?

  nonisolated struct Pipeline: Decodable, Equatable {
    let id: Int
    let status: String?
    let webUrl: String?

    private enum CodingKeys: String, CodingKey {
      case id
      case status
      case webUrl = "web_url"
    }
  }

  private enum CodingKeys: String, CodingKey {
    case iid
    case detailedMergeStatus = "detailed_merge_status"
    case hasConflicts = "has_conflicts"
    case headPipeline = "head_pipeline"
  }

  var pullRequestDetail: ForgePullRequestDetail {
    GitLabMergeStatusMapping.pullRequestDetail(for: self)
  }
}

/// Adapter-owned table over GitLab's `detailed_merge_status` vocabulary.
/// Unmapped and in-flight values degrade to a non-blocking pending state,
/// never to blocked.
nonisolated enum GitLabMergeStatusMapping {
  static func pullRequestDetail(for detail: GitLabMergeRequestDetail) -> ForgePullRequestDetail {
    let status = detail.detailedMergeStatus?.lowercased()
    var mergeable: String?
    var reviewDecision: String?
    var blockedReason: String?
    switch status {
    case "mergeable":
      mergeable = "MERGEABLE"
    case "conflict":
      mergeable = "CONFLICTING"
    case "requested_changes":
      reviewDecision = "CHANGES_REQUESTED"
    default:
      if detail.hasConflicts == true {
        mergeable = "CONFLICTING"
      } else {
        blockedReason = status.flatMap(Self.blockedProse)
      }
    }
    return ForgePullRequestDetail(
      mergeable: mergeable,
      mergeStateStatus: nil,
      reviewDecision: reviewDecision,
      statusCheckRollup: Self.rollup(for: detail.headPipeline),
      forgeBlockedReason: blockedReason
    )
  }

  /// Blocking statuses rendered with their own prose. Pending-style statuses
  /// (checking, unchecked, ci_still_running, approvals_syncing, ...) are
  /// deliberately absent so they fall through to the checking assessment.
  static func blockedProse(_ status: String) -> String? {
    switch status {
    case "not_approved": "Not approved"
    case "ci_must_pass": "Pipeline must succeed"
    case "discussions_not_resolved": "Unresolved discussions"
    case "draft_status": "Draft"
    case "need_rebase": "Needs rebase"
    case "blocked_status": "Blocked by another merge request"
    case "policies_denied": "Denied by policy"
    case "jira_association_missing": "Missing Jira association"
    case "commits_status": "Nothing to merge"
    case "external_status_checks": "External status checks must pass"
    case "locked_paths", "locked_lfs_files": "Locked files"
    default: nil
    }
  }

  private static func rollup(for pipeline: GitLabMergeRequestDetail.Pipeline?) -> ForgePullRequestStatusCheckRollup? {
    guard let pipeline else { return nil }
    return rollup(status: pipeline.status, detailsUrl: pipeline.webUrl)
  }

  /// Single-check rollup from a pipeline status; REST and GraphQL spellings
  /// only differ by case.
  static func rollup(status pipelineStatus: String?, detailsUrl: String?) -> ForgePullRequestStatusCheckRollup {
    let status: String
    var conclusion: String?
    switch pipelineStatus?.lowercased() {
    case "success":
      status = "COMPLETED"
      conclusion = "SUCCESS"
    case "failed":
      status = "COMPLETED"
      conclusion = "FAILURE"
    case "canceled", "skipped":
      status = "COMPLETED"
      conclusion = "SKIPPED"
    default:
      status = "IN_PROGRESS"
    }
    let check = ForgePullRequestStatusCheck(
      name: "Pipeline",
      detailsUrl: detailsUrl,
      status: status,
      conclusion: conclusion
    )
    return ForgePullRequestStatusCheckRollup(checks: [check])
  }
}
