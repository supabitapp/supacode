import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

extension ForgeID {
  nonisolated static let gitlab = ForgeID(rawValue: "gitlab")
}

extension ForgeClient {
  /// The GitLab witness cannot act without a resolved project.
  nonisolated private static func requireGitLabProject(_ project: ForgeProjectRef?) throws -> ForgeProjectRef {
    guard let project else {
      throw GitLabCLIError.commandFailed("Could not resolve the GitLab project for this repository.")
    }
    return project
  }

  /// GitLab adapter: dispatches to the glab-backed client resolved at call
  /// time, so dependency overrides in tests keep applying.
  nonisolated static var gitlab: ForgeClient {
    ForgeClient(
      resolveProject: { repositoryRootURL in
        @Dependency(GitClientDependency.self) var gitClient
        guard let remote = await gitClient.gitRemote(repositoryRootURL) else { return nil }
        return ForgeProjectRef(forgeID: .gitlab, host: remote.host, pathSegments: remote.pathComponents)
      },
      fetchSummaries: { project, branches in
        @Dependency(GitLabCLIClient.self) var gitlabCLI
        return try await gitlabCLI.fetchMergeRequests(project.host, project.path, branches)
      },
      fetchDetail: { project, number in
        @Dependency(GitLabCLIClient.self) var gitlabCLI
        return try await gitlabCLI.fetchMergeRequestDetail(project.host, project.path, number)
      },
      mergePullRequest: { worktreeRoot, project, number, strategy in
        @Dependency(GitLabCLIClient.self) var gitlabCLI
        let project = try requireGitLabProject(project)
        try await gitlabCLI.mergeMergeRequest(worktreeRoot, project.host, project.path, number, strategy)
      },
      closePullRequest: { worktreeRoot, project, number in
        @Dependency(GitLabCLIClient.self) var gitlabCLI
        let project = try requireGitLabProject(project)
        try await gitlabCLI.closeMergeRequest(worktreeRoot, project.host, project.path, number)
      },
      markPullRequestReady: { worktreeRoot, project, number in
        @Dependency(GitLabCLIClient.self) var gitlabCLI
        let project = try requireGitLabProject(project)
        try await gitlabCLI.markMergeRequestReady(worktreeRoot, project.host, project.path, number)
      },
      latestRun: { worktreeRoot, branch in
        @Dependency(GitClientDependency.self) var gitClient
        @Dependency(GitLabCLIClient.self) var gitlabCLI
        guard let remote = await gitClient.gitRemote(worktreeRoot) else { return nil }
        return try await gitlabCLI.latestPipeline(remote.host, remote.path, branch)
      },
      rerunFailedJobs: { worktreeRoot, pipelineID in
        @Dependency(GitClientDependency.self) var gitClient
        @Dependency(GitLabCLIClient.self) var gitlabCLI
        guard let remote = await gitClient.gitRemote(worktreeRoot) else {
          throw GitLabCLIError.commandFailed("Could not resolve the GitLab project for this repository.")
        }
        try await gitlabCLI.retryPipeline(remote.host, remote.path, pipelineID)
      },
      failedRunLogs: { _, _ in
        throw ForgeClientError.unsupported(operation: "CI failure logs")
      },
      runLogs: { _, _ in
        throw ForgeClientError.unsupported(operation: "CI logs")
      },
      isAvailable: {
        @Dependency(GitLabCLIClient.self) var gitlabCLI
        return await gitlabCLI.isAvailable()
      }
    )
  }
}
