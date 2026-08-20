import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated enum GitLabCLIError: LocalizedError, Equatable {
  case unavailable
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "GitLab CLI is not available"
    case .commandFailed(let message):
      return message
    }
  }
}

/// glab-backed GitLab adapter. Every invocation names its host explicitly
/// (`--hostname` for `glab api`, a full `-R` URL otherwise) so a stray
/// `GITLAB_HOST` in the user's login shell can never retarget a call.
struct GitLabCLIClient: Sendable {
  var fetchMergeRequests: @Sendable (String, String, [String]) async throws -> [String: ForgePullRequest]
  var fetchMergeRequestDetail: @Sendable (String, String, Int) async throws -> ForgePullRequestDetail?
  var latestPipeline: @Sendable (String, String, String) async throws -> ForgeWorkflowRun?
  var retryPipeline: @Sendable (String, String, Int) async throws -> Void
  var mergeMergeRequest: @Sendable (URL, String, String, Int, PullRequestMergeStrategy) async throws -> Void
  var closeMergeRequest: @Sendable (URL, String, String, Int) async throws -> Void
  var markMergeRequestReady: @Sendable (URL, String, String, Int) async throws -> Void
  var isAvailable: @Sendable () async -> Bool
  var authenticatedHosts: @Sendable () async -> Set<String>
}

extension GitLabCLIClient: DependencyKey {
  static let liveValue = live()

  static func live(
    shell: ShellClient = .liveValue,
    fallbackExecutableURLs: [URL] = ForgeCLIExecutableResolver.defaultFallbackExecutableURLs(executableName: "glab")
  ) -> GitLabCLIClient {
    let resolver = ForgeCLIExecutableResolver(
      executableName: "glab",
      fallbackExecutableURLs: fallbackExecutableURLs
    )
    return GitLabCLIClient(
      fetchMergeRequests: fetchMergeRequestsFetcher(shell: shell, resolver: resolver),
      fetchMergeRequestDetail: fetchMergeRequestDetailFetcher(shell: shell, resolver: resolver),
      latestPipeline: latestPipelineFetcher(shell: shell, resolver: resolver),
      retryPipeline: retryPipelineFetcher(shell: shell, resolver: resolver),
      mergeMergeRequest: mergeMergeRequestFetcher(shell: shell, resolver: resolver),
      closeMergeRequest: closeMergeRequestFetcher(shell: shell, resolver: resolver),
      markMergeRequestReady: markMergeRequestReadyFetcher(shell: shell, resolver: resolver),
      isAvailable: isAvailableFetcher(shell: shell, resolver: resolver),
      authenticatedHosts: {
        guard
          let configURL = GitLabConfigHosts.configFileURL(),
          let configYAML = try? String(contentsOf: configURL, encoding: .utf8)
        else {
          return []
        }
        return GitLabConfigHosts.parse(configYAML: configYAML)
      }
    )
  }

  static let testValue = GitLabCLIClient(
    fetchMergeRequests: { _, _, _ in [:] },
    fetchMergeRequestDetail: { _, _, _ in nil },
    latestPipeline: { _, _, _ in nil },
    retryPipeline: { _, _, _ in },
    mergeMergeRequest: { _, _, _, _, _ in },
    closeMergeRequest: { _, _, _, _ in },
    markMergeRequestReady: { _, _, _, _ in },
    isAvailable: { true },
    authenticatedHosts: { ["gitlab.com"] }
  )
}

nonisolated enum GitLabAPI {
  /// GitLab REST project ids are the full namespace path with `/` escaped.
  static func encodedProjectPath(_ path: String) -> String {
    path.replacing("/", with: "%2F")
  }

  static func repoURL(host: String, path: String) -> String {
    "https://\(host)/\(path)"
  }

  /// GitLab timestamps carry fractional seconds; gh-style plain ISO8601 does
  /// not, so try both.
  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let raw = try decoder.singleValueContainer().decode(String.self)
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractional.date(from: raw) {
        return date
      }
      let plain = ISO8601DateFormatter()
      if let date = plain.date(from: raw) {
        return date
      }
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Unrecognized GitLab date: \(raw)"
        )
      )
    }
    return decoder
  }
}

nonisolated private func fetchMergeRequestsFetcher(
  shell: ShellClient,
  resolver: ForgeCLIExecutableResolver
) -> @Sendable (String, String, [String]) async throws -> [String: ForgePullRequest] {
  { host, projectPath, branches in
    let encodedPath = GitLabAPI.encodedProjectPath(projectPath)
    let listOutput = try await runGlab(
      shell: shell,
      resolver: resolver,
      arguments: [
        "api", "--hostname", host,
        "projects/\(encodedPath)/merge_requests?state=all&order_by=updated_at&sort=desc&per_page=100",
      ],
      repoRoot: nil
    )
    let decoder = GitLabAPI.makeDecoder()
    var mergeRequests = try GithubCLIOutput.decode([GitLabMergeRequest].self, from: listOutput, decoder: decoder)
    // A full page may have pushed an older worktree's merge request out; look
    // those branches up individually so a proposal never silently reads as
    // absent (which would clear the row and break the merged transition).
    if mergeRequests.count == 100 {
      let coveredBranches = Set(mergeRequests.compactMap(\.sourceBranch))
      for branch in branches where !coveredBranches.contains(branch) {
        guard
          let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { continue }
        let branchOutput = try await runGlab(
          shell: shell,
          resolver: resolver,
          arguments: [
            "api", "--hostname", host,
            "projects/\(encodedPath)/merge_requests?state=all&order_by=updated_at&sort=desc&per_page=1"
              + "&source_branch=\(encodedBranch)",
          ],
          repoRoot: nil
        )
        let extra = try GithubCLIOutput.decode([GitLabMergeRequest].self, from: branchOutput, decoder: decoder)
        mergeRequests.append(contentsOf: extra)
      }
    }
    return GitLabMergeRequest.pullRequestsByBranch(mergeRequests, branches: branches)
  }
}

nonisolated private func mergeMergeRequestFetcher(
  shell: ShellClient,
  resolver: ForgeCLIExecutableResolver
) -> @Sendable (URL, String, String, Int, PullRequestMergeStrategy) async throws -> Void {
  { repoRoot, host, projectPath, number, strategy in
    var arguments = [
      "mr", "merge", "\(number)",
      "-R", GitLabAPI.repoURL(host: host, path: projectPath),
      "-y",
      // Explicit: glab defaults auto-merge ON while a pipeline runs, which
      // would silently queue a merge the UI reports as done.
      "--auto-merge=false",
    ]
    switch strategy {
    case .squash:
      arguments.append("--squash")
    case .merge:
      break
    case .rebase:
      // GitLab's merge method is a project setting; a per-merge rebase choice
      // does not exist.
      throw ForgeClientError.unsupported(operation: "rebase merges")
    }
    _ = try await runGlab(shell: shell, resolver: resolver, arguments: arguments, repoRoot: repoRoot)
  }
}

nonisolated private func closeMergeRequestFetcher(
  shell: ShellClient,
  resolver: ForgeCLIExecutableResolver
) -> @Sendable (URL, String, String, Int) async throws -> Void {
  { repoRoot, host, projectPath, number in
    _ = try await runGlab(
      shell: shell,
      resolver: resolver,
      arguments: ["mr", "close", "\(number)", "-R", GitLabAPI.repoURL(host: host, path: projectPath)],
      repoRoot: repoRoot
    )
  }
}

nonisolated private func markMergeRequestReadyFetcher(
  shell: ShellClient,
  resolver: ForgeCLIExecutableResolver
) -> @Sendable (URL, String, String, Int) async throws -> Void {
  { repoRoot, host, projectPath, number in
    _ = try await runGlab(
      shell: shell,
      resolver: resolver,
      arguments: ["mr", "update", "\(number)", "--ready", "-R", GitLabAPI.repoURL(host: host, path: projectPath)],
      repoRoot: repoRoot
    )
  }
}

nonisolated private func isAvailableFetcher(
  shell: ShellClient,
  resolver: ForgeCLIExecutableResolver
) -> @Sendable () async -> Bool {
  {
    do {
      _ = try await runGlab(shell: shell, resolver: resolver, arguments: ["--version"], repoRoot: nil)
      return true
    } catch {
      return false
    }
  }
}

nonisolated private func runGlab(
  shell: ShellClient,
  resolver: ForgeCLIExecutableResolver,
  arguments: [String],
  repoRoot: URL?
) async throws -> String {
  let command = (["glab"] + arguments).joined(separator: " ")
  do {
    let executableURL = try await resolver.executableURL(shell: shell)
    do {
      return try await shell.runLogin(executableURL, arguments, repoRoot, log: false).stdout
    } catch {
      guard ForgeCLIExecutableResolver.shouldRetryExecution(after: error) else {
        throw error
      }
      await resolver.invalidate()
      let executableURL = try await resolver.executableURL(shell: shell)
      return try await shell.runLogin(executableURL, arguments, repoRoot, log: false).stdout
    }
  } catch is ForgeCLIResolutionError {
    throw GitLabCLIError.unavailable
  } catch let error as GitLabCLIError {
    throw error
  } catch {
    if let shellError = error as? ShellClientError {
      let message = shellError.errorDescription ?? "Command failed: \(command)"
      throw GitLabCLIError.commandFailed(message)
    }
    throw GitLabCLIError.commandFailed(error.localizedDescription)
  }
}

nonisolated private func fetchMergeRequestDetailFetcher(
  shell: ShellClient,
  resolver: ForgeCLIExecutableResolver
) -> @Sendable (String, String, Int) async throws -> ForgePullRequestDetail? {
  { host, projectPath, number in
    let encodedPath = GitLabAPI.encodedProjectPath(projectPath)
    let output = try await runGlab(
      shell: shell,
      resolver: resolver,
      arguments: ["api", "--hostname", host, "projects/\(encodedPath)/merge_requests/\(number)"],
      repoRoot: nil
    )
    let decoder = GitLabAPI.makeDecoder()
    let detail = try GithubCLIOutput.decode(GitLabMergeRequestDetail.self, from: output, decoder: decoder)
    return detail.pullRequestDetail
  }
}

nonisolated private func latestPipelineFetcher(
  shell: ShellClient,
  resolver: ForgeCLIExecutableResolver
) -> @Sendable (String, String, String) async throws -> ForgeWorkflowRun? {
  { host, projectPath, branch in
    let encodedPath = GitLabAPI.encodedProjectPath(projectPath)
    guard let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
      return nil
    }
    let output = try await runGlab(
      shell: shell,
      resolver: resolver,
      arguments: [
        "api", "--hostname", host,
        "projects/\(encodedPath)/pipelines?ref=\(encodedBranch)&per_page=1&order_by=updated_at&sort=desc",
      ],
      repoRoot: nil
    )
    let decoder = GitLabAPI.makeDecoder()
    guard
      let pipelines = try GithubCLIOutput.decodeIfPresent([GitLabPipeline].self, from: output, decoder: decoder),
      let pipeline = pipelines.first
    else {
      return nil
    }
    return pipeline.workflowRun
  }
}

nonisolated private func retryPipelineFetcher(
  shell: ShellClient,
  resolver: ForgeCLIExecutableResolver
) -> @Sendable (String, String, Int) async throws -> Void {
  { host, projectPath, pipelineID in
    let encodedPath = GitLabAPI.encodedProjectPath(projectPath)
    _ = try await runGlab(
      shell: shell,
      resolver: resolver,
      arguments: [
        "api", "--hostname", host, "--method", "POST",
        "projects/\(encodedPath)/pipelines/\(pipelineID)/retry",
      ],
      repoRoot: nil
    )
  }
}

/// GitLab pipeline list object mapped onto the shared workflow-run shape so
/// the existing rerun flow works unchanged.
nonisolated struct GitLabPipeline: Decodable, Equatable {
  let id: Int
  let status: String?
  let ref: String?
  let webUrl: String?
  let createdAt: Date?
  let updatedAt: Date?

  private enum CodingKeys: String, CodingKey {
    case id
    case status
    case ref
    case webUrl = "web_url"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  var workflowRun: ForgeWorkflowRun {
    let conclusion: String? =
      switch status?.lowercased() {
      case "success": "success"
      case "failed": "failure"
      case "canceled", "skipped": "cancelled"
      default: nil
      }
    return ForgeWorkflowRun(
      databaseId: id,
      workflowName: "Pipeline",
      name: "Pipeline",
      displayTitle: ref ?? "Pipeline",
      status: status ?? "unknown",
      conclusion: conclusion,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}
