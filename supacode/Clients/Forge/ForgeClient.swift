import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Stable identity for a forge implementation. A string id so future forges
/// (including script-defined ones) never force a schema migration.
nonisolated struct ForgeID: RawRepresentable, Hashable, Sendable, Codable {
  let rawValue: String

  static let github = ForgeID(rawValue: "github")
}

/// Opaque project identity minted by the adapter that resolved the remote.
/// `pathSegments` is the full namespace path: exactly owner/repo on GitHub,
/// arbitrarily deep on forges with nested namespaces.
nonisolated struct ForgeProjectRef: Equatable, Hashable, Sendable {
  let forgeID: ForgeID
  let host: String
  let pathSegments: [String]

  var path: String {
    pathSegments.joined(separator: "/")
  }
}

/// Detail-tier payload; no `state`/`mergedAt` fields so a detail refresh can
/// never influence the merged-worktree transition.
nonisolated struct ForgePullRequestDetail: Equatable, Sendable {
  let mergeable: String?
  let mergeStateStatus: String?
  let reviewDecision: String?
  let statusCheckRollup: ForgePullRequestStatusCheckRollup?
  /// Forge-reported merge block outside the shared vocabulary, verbatim.
  let forgeBlockedReason: String?

  init(
    mergeable: String? = nil,
    mergeStateStatus: String? = nil,
    reviewDecision: String? = nil,
    statusCheckRollup: ForgePullRequestStatusCheckRollup? = nil,
    forgeBlockedReason: String? = nil
  ) {
    self.mergeable = mergeable
    self.mergeStateStatus = mergeStateStatus
    self.reviewDecision = reviewDecision
    self.statusCheckRollup = statusCheckRollup
    self.forgeBlockedReason = forgeBlockedReason
  }
}

extension ForgePullRequest {
  /// The detail-tier fields, exactly the set `applying(_:)` replaces.
  nonisolated var detail: ForgePullRequestDetail {
    ForgePullRequestDetail(
      mergeable: mergeable,
      mergeStateStatus: mergeStateStatus,
      reviewDecision: reviewDecision,
      statusCheckRollup: statusCheckRollup,
      forgeBlockedReason: forgeBlockedReason
    )
  }

  /// Detail-tier enrichment: replaces only the detail fields. `state`,
  /// `mergedAt`, and identity always come from the summary tier.
  nonisolated func applying(_ detail: ForgePullRequestDetail) -> ForgePullRequest {
    ForgePullRequest(
      number: number,
      title: title,
      state: state,
      additions: additions,
      deletions: deletions,
      isDraft: isDraft,
      reviewDecision: detail.reviewDecision,
      mergeable: detail.mergeable,
      mergeStateStatus: detail.mergeStateStatus,
      updatedAt: updatedAt,
      mergedAt: mergedAt,
      url: url,
      headRefName: headRefName,
      baseRefName: baseRefName,
      commitsCount: commitsCount,
      authorLogin: authorLogin,
      statusCheckRollup: detail.statusCheckRollup,
      mergeQueueEntry: mergeQueueEntry,
      forgeBlockedReason: detail.forgeBlockedReason,
      numberSigil: numberSigil
    )
  }
}

nonisolated enum ForgeClientError: LocalizedError, Equatable {
  case unsupported(operation: String)

  var errorDescription: String? {
    switch self {
    case .unsupported(let operation):
      return "This forge does not support \(operation)."
    }
  }
}

/// Forge-neutral seam over a forge CLI. Adapters own their transport strategy
/// (batching, retries, per-branch call plans); every endpoint here is a domain
/// operation, never a specific CLI invocation.
struct ForgeClient: Sendable {
  var resolveProject: @MainActor @Sendable (URL) async -> ForgeProjectRef?
  /// Summary tier: one call plan per refresh for all queried branches. Must
  /// report merged proposals, never silently drop them, so the
  /// merged-worktree transition can fire.
  var fetchSummaries: @MainActor @Sendable (ForgeProjectRef, [String]) async throws -> [String: ForgePullRequest]
  /// Detail tier: enrich the selected worktree's proposal. Adapters whose
  /// summaries are already rich return nil.
  var fetchDetail: @MainActor @Sendable (ForgeProjectRef, Int) async throws -> ForgePullRequestDetail?
  var mergePullRequest: @MainActor @Sendable (URL, ForgeProjectRef?, Int, PullRequestMergeStrategy) async throws -> Void
  var closePullRequest: @MainActor @Sendable (URL, ForgeProjectRef?, Int) async throws -> Void
  var markPullRequestReady: @MainActor @Sendable (URL, ForgeProjectRef?, Int) async throws -> Void
  var latestRun: @MainActor @Sendable (URL, String) async throws -> ForgeWorkflowRun?
  var rerunFailedJobs: @MainActor @Sendable (URL, Int) async throws -> Void
  var failedRunLogs: @MainActor @Sendable (URL, Int) async throws -> String
  var runLogs: @MainActor @Sendable (URL, Int) async throws -> String
  var isAvailable: @MainActor @Sendable () async -> Bool
}

extension ForgeClient {
  /// GitHub adapter: dispatches to the gh-backed client resolved at call time,
  /// so dependency overrides in tests keep applying.
  nonisolated static var github: ForgeClient {
    ForgeClient(
      resolveProject: { repositoryRootURL in
        @Dependency(GithubCLIClient.self) var githubCLI
        @Dependency(GitClientDependency.self) var gitClient
        // `gh repo view` honours the user's default-repo resolution (fork ->
        // upstream), so it wins; the git remote parser is the offline fallback.
        var info = await githubCLI.resolveRemoteInfo(repositoryRootURL)
        if info == nil {
          info = await gitClient.remoteInfo(repositoryRootURL)
        }
        guard let info else { return nil }
        return ForgeProjectRef(forgeID: .github, host: info.host, pathSegments: [info.owner, info.repo])
      },
      fetchSummaries: { project, branches in
        @Dependency(GithubCLIClient.self) var githubCLI
        guard project.pathSegments.count == 2 else { return [:] }
        return try await githubCLI.batchPullRequests(
          project.host,
          project.pathSegments[0],
          project.pathSegments[1],
          branches
        )
      },
      fetchDetail: { _, _ in
        // GitHub summaries already carry the full detail tier.
        nil
      },
      mergePullRequest: { worktreeRoot, project, number, strategy in
        @Dependency(GithubCLIClient.self) var githubCLI
        try await githubCLI.mergePullRequest(worktreeRoot, project.flatMap(GithubRemoteInfo.init), number, strategy)
      },
      closePullRequest: { worktreeRoot, project, number in
        @Dependency(GithubCLIClient.self) var githubCLI
        try await githubCLI.closePullRequest(worktreeRoot, project.flatMap(GithubRemoteInfo.init), number)
      },
      markPullRequestReady: { worktreeRoot, project, number in
        @Dependency(GithubCLIClient.self) var githubCLI
        try await githubCLI.markPullRequestReady(worktreeRoot, project.flatMap(GithubRemoteInfo.init), number)
      },
      latestRun: { worktreeRoot, branch in
        @Dependency(GithubCLIClient.self) var githubCLI
        return try await githubCLI.latestRun(worktreeRoot, branch)
      },
      rerunFailedJobs: { worktreeRoot, runID in
        @Dependency(GithubCLIClient.self) var githubCLI
        try await githubCLI.rerunFailedJobs(worktreeRoot, runID)
      },
      failedRunLogs: { worktreeRoot, runID in
        @Dependency(GithubCLIClient.self) var githubCLI
        return try await githubCLI.failedRunLogs(worktreeRoot, runID)
      },
      runLogs: { worktreeRoot, runID in
        @Dependency(GithubCLIClient.self) var githubCLI
        return try await githubCLI.runLogs(worktreeRoot, runID)
      },
      isAvailable: {
        @Dependency(GithubCLIClient.self) var githubCLI
        return await githubCLI.isAvailable()
      }
    )
  }
}

extension ForgeClient: DependencyKey {
  static let liveValue = ForgeClient.github
  static let testValue = ForgeClient.github
}

extension GithubRemoteInfo {
  nonisolated init?(_ project: ForgeProjectRef) {
    guard project.pathSegments.count == 2 else { return nil }
    self.init(host: project.host, owner: project.pathSegments[0], repo: project.pathSegments[1])
  }
}
