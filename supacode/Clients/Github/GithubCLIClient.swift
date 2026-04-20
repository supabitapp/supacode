import ComposableArchitecture
import Darwin
import Foundation
import SupacodeSettingsShared

struct GithubAuthStatus: Equatable, Sendable {
  let username: String
  let host: String
}

private struct GithubAuthStatusResponse: Sendable {
  let hosts: [String: [GithubAuthAccount]]

  struct GithubAuthAccount: Sendable {
    let active: Bool
    let login: String
  }
}

extension GithubAuthStatusResponse: Decodable {
  private enum CodingKeys: String, CodingKey {
    case hosts
  }

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.hosts = try container.decode([String: [GithubAuthAccount]].self, forKey: .hosts)
  }
}

extension GithubAuthStatusResponse.GithubAuthAccount: Decodable {
  private enum CodingKeys: String, CodingKey {
    case active
    case login
  }

  nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.active = try container.decode(Bool.self, forKey: .active)
    self.login = try container.decode(String.self, forKey: .login)
  }
}

struct GithubCLIClient: Sendable {
  var defaultBranch: @Sendable (URL) async throws -> String
  var latestRun: @Sendable (URL, String) async throws -> GithubWorkflowRun?
  var resolveRemoteInfo: @Sendable (URL) async -> GithubRemoteInfo?
  var batchPullRequests: @Sendable (String, String, String, [String]) async throws -> [String: GithubPullRequest]
  var mergePullRequest: @Sendable (URL, GithubRemoteInfo?, Int, PullRequestMergeStrategy) async throws -> Void
  var closePullRequest: @Sendable (URL, GithubRemoteInfo?, Int) async throws -> Void
  var markPullRequestReady: @Sendable (URL, GithubRemoteInfo?, Int) async throws -> Void
  var rerunFailedJobs: @Sendable (URL, Int) async throws -> Void
  var failedRunLogs: @Sendable (URL, Int) async throws -> String
  var runLogs: @Sendable (URL, Int) async throws -> String
  var isAvailable: @Sendable () async -> Bool
  var authStatus: @Sendable () async throws -> GithubAuthStatus?
}

extension GithubCLIClient: DependencyKey {
  static let liveValue = live()

  static func live(shell: ShellClient = .liveValue) -> GithubCLIClient {
    let resolver = GithubCLIExecutableResolver()
    return GithubCLIClient(
      defaultBranch: defaultBranchFetcher(shell: shell, resolver: resolver),
      latestRun: latestRunFetcher(shell: shell, resolver: resolver),
      resolveRemoteInfo: resolveRemoteInfoFetcher(shell: shell, resolver: resolver),
      batchPullRequests: batchPullRequestsFetcher(shell: shell, resolver: resolver),
      mergePullRequest: mergePullRequestFetcher(shell: shell, resolver: resolver),
      closePullRequest: closePullRequestFetcher(shell: shell, resolver: resolver),
      markPullRequestReady: markPullRequestReadyFetcher(shell: shell, resolver: resolver),
      rerunFailedJobs: rerunFailedJobsFetcher(shell: shell, resolver: resolver),
      failedRunLogs: failedRunLogsFetcher(shell: shell, resolver: resolver),
      runLogs: runLogsFetcher(shell: shell, resolver: resolver),
      isAvailable: isAvailableFetcher(shell: shell, resolver: resolver),
      authStatus: authStatusFetcher(shell: shell, resolver: resolver)
    )
  }

  static let testValue = GithubCLIClient(
    defaultBranch: { _ in "main" },
    latestRun: { _, _ in nil },
    resolveRemoteInfo: { _ in nil },
    batchPullRequests: { _, _, _, _ in [:] },
    mergePullRequest: { _, _, _, _ in },
    closePullRequest: { _, _, _ in },
    markPullRequestReady: { _, _, _ in },
    rerunFailedJobs: { _, _ in },
    failedRunLogs: { _, _ in "" },
    runLogs: { _, _ in "" },
    isAvailable: { true },
    authStatus: { GithubAuthStatus(username: "testuser", host: "github.com") }
  )
}

extension DependencyValues {
  var githubCLI: GithubCLIClient {
    get { self[GithubCLIClient.self] }
    set { self[GithubCLIClient.self] = newValue }
  }
}

private struct GithubPullRequestsRequest: Sendable {
  let host: String
  let owner: String
  let repo: String
}

private actor GithubCLIExecutableResolver {
  private var cachedExecutableURL: URL?
  private var inFlightResolution: Task<URL, Error>?

  func executableURL(shell: ShellClient) async throws -> URL {
    if let cachedExecutableURL {
      return cachedExecutableURL
    }
    if let inFlightResolution {
      return try await inFlightResolution.value
    }
    let resolutionTask = Task {
      try await resolveExecutableURL(shell: shell)
    }
    inFlightResolution = resolutionTask
    do {
      let executableURL = try await resolutionTask.value
      cachedExecutableURL = executableURL
      inFlightResolution = nil
      return executableURL
    } catch {
      inFlightResolution = nil
      throw error
    }
  }

  func invalidate() {
    cachedExecutableURL = nil
    inFlightResolution?.cancel()
    inFlightResolution = nil
  }

  private func resolveExecutableURL(shell: ShellClient) async throws -> URL {
    if let executableURL = await locateExecutableURL(
      shell: shell,
      useLoginShell: false
    ) {
      return executableURL
    }
    if let executableURL = await locateExecutableURL(
      shell: shell,
      useLoginShell: true
    ) {
      return executableURL
    }
    throw GithubCLIError.unavailable
  }

  private func locateExecutableURL(
    shell: ShellClient,
    useLoginShell: Bool
  ) async -> URL? {
    let whichURL = URL(fileURLWithPath: "/usr/bin/which")
    do {
      let output: String
      if useLoginShell {
        output = try await shell.runLogin(
          whichURL,
          ["gh"],
          nil,
          log: false
        ).stdout
      } else {
        output = try await shell.run(whichURL, ["gh"], nil).stdout
      }
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        return nil
      }
      return URL(fileURLWithPath: trimmed)
    } catch {
      return nil
    }
  }
}

nonisolated private func defaultBranchFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL) async throws -> String {
  { repoRoot in
    let output = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: ["repo", "view", "--json", "defaultBranchRef"],
      repoRoot: repoRoot
    )
    let data = Data(output.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(GithubRepoViewResponse.self, from: data)
    return response.defaultBranchRef.name
  }
}

nonisolated private func latestRunFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, String) async throws -> GithubWorkflowRun? {
  { repoRoot, branch in
    let output = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: [
        "run",
        "list",
        "--branch",
        branch,
        "--limit",
        "1",
        "--json",
        "databaseId,workflowName,name,displayTitle,status,conclusion,createdAt,updatedAt",
      ],
      repoRoot: repoRoot
    )
    if output.isEmpty {
      return nil
    }
    let data = Data(output.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let runs = try decoder.decode([GithubWorkflowRun].self, from: data)
    return runs.first
  }
}

nonisolated private struct GithubRepoViewRemoteInfoResponse: Decodable, Sendable {
  let name: String
  let owner: Owner
  let url: String?

  nonisolated struct Owner: Decodable, Sendable {
    let login: String
  }
}

nonisolated private func resolveRemoteInfoFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL) async -> GithubRemoteInfo? {
  { repoRoot in
    do {
      let output = try await runGh(
        shell: shell,
        resolver: resolver,
        arguments: ["repo", "view", "--json", "owner,name,url"],
        repoRoot: repoRoot
      )
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        return nil
      }
      let response = try JSONDecoder().decode(
        GithubRepoViewRemoteInfoResponse.self,
        from: Data(trimmed.utf8)
      )
      let host = hostFromRepoViewURL(response.url) ?? "github.com"
      guard !response.owner.login.isEmpty, !response.name.isEmpty else {
        return nil
      }
      return GithubRemoteInfo(
        host: host,
        owner: response.owner.login,
        repo: response.name
      )
    } catch {
      return nil
    }
  }
}

nonisolated private func hostFromRepoViewURL(_ urlString: String?) -> String? {
  guard let urlString, !urlString.isEmpty,
    let url = URL(string: urlString),
    let host = url.host,
    !host.isEmpty
  else {
    return nil
  }
  return host
}

nonisolated private func repoSlug(for remote: GithubRemoteInfo) -> String {
  "\(remote.host)/\(remote.owner)/\(remote.repo)"
}

nonisolated private func batchPullRequestsFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (String, String, String, [String]) async throws -> [String: GithubPullRequest] {
  { host, owner, repo, branches in
    let dedupedBranches = deduplicatedBranches(branches)
    guard !dedupedBranches.isEmpty else {
      return [:]
    }
    let request = GithubPullRequestsRequest(host: host, owner: owner, repo: repo)
    let chunks = makeBranchChunks(
      dedupedBranches,
      chunkSize: batchPullRequestsChunkSize
    )
    let chunkResults = try await loadPullRequestChunks(
      shell: shell,
      resolver: resolver,
      request: request,
      chunks: chunks
    )
    return mergePullRequestChunkResults(
      chunkResults,
      chunkCount: chunks.count
    )
  }
}

nonisolated private func mergePullRequestFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, GithubRemoteInfo?, Int, PullRequestMergeStrategy) async throws -> Void {
  { repoRoot, remote, pullRequestNumber, strategy in
    var arguments: [String] = ["pr", "merge", "\(pullRequestNumber)", "--\(strategy.ghArgument)"]
    if let remote {
      arguments.append(contentsOf: ["--repo", repoSlug(for: remote)])
    }
    _ = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: arguments,
      repoRoot: repoRoot
    )
  }
}

nonisolated private func closePullRequestFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, GithubRemoteInfo?, Int) async throws -> Void {
  { repoRoot, remote, pullRequestNumber in
    var arguments: [String] = ["pr", "close", "\(pullRequestNumber)"]
    if let remote {
      arguments.append(contentsOf: ["--repo", repoSlug(for: remote)])
    }
    _ = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: arguments,
      repoRoot: repoRoot
    )
  }
}

nonisolated private func markPullRequestReadyFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, GithubRemoteInfo?, Int) async throws -> Void {
  { repoRoot, remote, pullRequestNumber in
    var arguments: [String] = ["pr", "ready", "\(pullRequestNumber)"]
    if let remote {
      arguments.append(contentsOf: ["--repo", repoSlug(for: remote)])
    }
    _ = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: arguments,
      repoRoot: repoRoot
    )
  }
}

nonisolated private func rerunFailedJobsFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, Int) async throws -> Void {
  { repoRoot, runID in
    _ = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: [
        "run",
        "rerun",
        "\(runID)",
        "--failed",
      ],
      repoRoot: repoRoot
    )
  }
}

nonisolated private func failedRunLogsFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, Int) async throws -> String {
  { repoRoot, runID in
    try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: [
        "run",
        "view",
        "\(runID)",
        "--log-failed",
      ],
      repoRoot: repoRoot
    )
  }
}

nonisolated private func runLogsFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable (URL, Int) async throws -> String {
  { repoRoot, runID in
    try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: [
        "run",
        "view",
        "\(runID)",
        "--log",
      ],
      repoRoot: repoRoot
    )
  }
}

nonisolated private func isAvailableFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable () async -> Bool {
  {
    do {
      _ = try await runGh(
        shell: shell,
        resolver: resolver,
        arguments: ["--version"],
        repoRoot: nil
      )
      return true
    } catch {
      return false
    }
  }
}

nonisolated private func authStatusFetcher(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver
) -> @Sendable () async throws -> GithubAuthStatus? {
  {
    let output = try await runGh(
      shell: shell,
      resolver: resolver,
      arguments: ["auth", "status", "--json", "hosts"],
      repoRoot: nil
    )
    let data = Data(output.utf8)
    let response = try decodeAuthStatusResponse(from: data)
    guard let (host, accounts) = response.hosts.first,
      let activeAccount = accounts.first(where: { $0.active })
    else {
      return nil
    }
    return GithubAuthStatus(username: activeAccount.login, host: host)
  }
}

nonisolated private func deduplicatedBranches(_ branches: [String]) -> [String] {
  var seen = Set<String>()
  return branches.filter { !$0.isEmpty && seen.insert($0).inserted }
}

nonisolated private let batchPullRequestsChunkSize = 25
nonisolated private let batchPullRequestsMaxConcurrentRequests = 3

nonisolated private func makeBranchChunks(
  _ branches: [String],
  chunkSize: Int
) -> [[String]] {
  guard !branches.isEmpty else {
    return []
  }

  var chunks: [[String]] = []
  var index = 0
  while index < branches.count {
    let end = min(index + chunkSize, branches.count)
    chunks.append(Array(branches[index..<end]))
    index = end
  }

  return chunks
}

nonisolated private func loadPullRequestChunks(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  request: GithubPullRequestsRequest,
  chunks: [[String]]
) async throws -> [Int: [String: GithubPullRequest]] {
  try await withThrowingTaskGroup(
    of: (Int, [String: GithubPullRequest]).self
  ) { group in
    var nextChunkIndex = 0
    let initialCount = min(batchPullRequestsMaxConcurrentRequests, chunks.count)
    while nextChunkIndex < initialCount {
      let chunkIndex = nextChunkIndex
      let chunk = chunks[chunkIndex]
      group.addTask {
        try await fetchPullRequestsChunk(
          shell: shell,
          resolver: resolver,
          request: request,
          chunk: chunk,
          chunkIndex: chunkIndex
        )
      }
      nextChunkIndex += 1
    }

    var resultsByChunkIndex: [Int: [String: GithubPullRequest]] = [:]
    while let (chunkIndex, prsByBranch) = try await group.next() {
      resultsByChunkIndex[chunkIndex] = prsByBranch
      if nextChunkIndex < chunks.count {
        let candidateIndex = nextChunkIndex
        let candidateChunk = chunks[candidateIndex]
        group.addTask {
          try await fetchPullRequestsChunk(
            shell: shell,
            resolver: resolver,
            request: request,
            chunk: candidateChunk,
            chunkIndex: candidateIndex
          )
        }
        nextChunkIndex += 1
      }
    }

    return resultsByChunkIndex
  }
}

nonisolated private func mergePullRequestChunkResults(
  _ chunkResults: [Int: [String: GithubPullRequest]],
  chunkCount: Int
) -> [String: GithubPullRequest] {
  var results: [String: GithubPullRequest] = [:]
  for chunkIndex in 0..<chunkCount {
    guard let prsByBranch = chunkResults[chunkIndex] else {
      continue
    }
    results.merge(prsByBranch) { _, new in new }
  }
  return results
}

nonisolated private func fetchPullRequestsChunk(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  request: GithubPullRequestsRequest,
  chunk: [String],
  chunkIndex: Int
) async throws -> (Int, [String: GithubPullRequest]) {
  let (query, aliasMap) = makeBatchPullRequestsQuery(branches: chunk)
  let output = try await runGh(
    shell: shell,
    resolver: resolver,
    arguments: [
      "api",
      "graphql",
      "--hostname",
      request.host,
      "-f",
      "query=\(query)",
      "-f",
      "owner=\(request.owner)",
      "-f",
      "repo=\(request.repo)",
    ],
    repoRoot: nil
  )
  guard !output.isEmpty else {
    return (chunkIndex, [:])
  }

  let data = Data(output.utf8)
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let response = try decoder.decode(GithubGraphQLPullRequestResponse.self, from: data)
  let prsByBranch = response.pullRequestsByBranch(
    aliasMap: aliasMap,
    owner: request.owner,
    repo: request.repo
  )
  return (chunkIndex, prsByBranch)
}

nonisolated private func makeBatchPullRequestsQuery(
  branches: [String]
) -> (query: String, aliasMap: [String: String]) {
  var aliasMap: [String: String] = [:]
  var selections: [String] = []
  for (index, branch) in branches.enumerated() {
    let alias = "branch\(index)"
    aliasMap[alias] = branch
    let escapedBranch = escapeGraphQLString(branch)
    let orderBy = "orderBy: {field: UPDATED_AT, direction: DESC}"
    let selection = """
      \(alias): pullRequests(first: 5, states: [OPEN, MERGED], headRefName: \"\(escapedBranch)\", \(orderBy)) {
        nodes {
          number
          title
          state
          additions
          deletions
          isDraft
          reviewDecision
          mergeable
          mergeStateStatus
          url
          updatedAt
          headRefName
          baseRefName
          commits {
            totalCount
          }
          author {
            login
          }
          headRepository {
            name
            owner { login }
          }
          statusCheckRollup {
            contexts(first: 100) {
              nodes {
                ... on CheckRun {
                  name
                  status
                  conclusion
                  startedAt
                  completedAt
                  detailsUrl
                }
                ... on StatusContext {
                  context
                  state
                  targetUrl
                  createdAt
                }
              }
            }
          }
        }
      }
      """
    selections.append(selection)
  }
  let selectionBlock = selections.joined(separator: "\n")
  let query = """
    query($owner: String!, $repo: String!) {
      repository(owner: $owner, name: $repo) {
    \(selectionBlock)
      }
    }
    """
  return (query, aliasMap)
}

nonisolated private func escapeGraphQLString(_ value: String) -> String {
  value
    .replacing("\\", with: "\\\\")
    .replacing("\"", with: "\\\"")
    .replacing("\n", with: "\\n")
    .replacing("\r", with: "\\r")
    .replacing("\t", with: "\\t")
}

nonisolated private func isOutdatedGitHubCLI(_ error: ShellClientError) -> Bool {
  let combined = "\(error.stdout)\n\(error.stderr)".lowercased()
  if combined.contains("unknown flag: --json") {
    return true
  }
  if combined.contains("unknown shorthand flag") && combined.contains("json") {
    return true
  }
  return false
}

nonisolated private func runGh(
  shell: ShellClient,
  resolver: GithubCLIExecutableResolver,
  arguments: [String],
  repoRoot: URL?
) async throws -> String {
  let command = (["gh"] + arguments).joined(separator: " ")
  do {
    let executableURL = try await resolver.executableURL(shell: shell)
    do {
      return try await shell.runLogin(executableURL, arguments, repoRoot, log: false).stdout
    } catch {
      guard shouldRetryGhExecution(after: error) else {
        throw error
      }
      await resolver.invalidate()
      let executableURL = try await resolver.executableURL(shell: shell)
      return try await shell.runLogin(executableURL, arguments, repoRoot, log: false).stdout
    }
  } catch let error as GithubCLIError {
    throw error
  } catch {
    if let shellError = error as? ShellClientError {
      if isOutdatedGitHubCLI(shellError) {
        throw GithubCLIError.outdated
      }
      let message = shellError.errorDescription ?? "Command failed: \(command)"
      throw GithubCLIError.commandFailed(message)
    }
    throw GithubCLIError.commandFailed(error.localizedDescription)
  }
}

nonisolated private func shouldRetryGhExecution(after error: Error) -> Bool {
  if let shellError = error as? ShellClientError {
    let combined = "\(shellError.stdout)\n\(shellError.stderr)".lowercased()
    if combined.contains("no such file or directory") || combined.contains("command not found") {
      return true
    }
    if shellError.exitCode == 127 {
      return true
    }
  }
  let nsError = error as NSError
  if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
    return true
  }
  if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT) {
    return true
  }
  return false
}

nonisolated private func decodeAuthStatusResponse(from data: Data) throws -> GithubAuthStatusResponse {
  try JSONDecoder().decode(GithubAuthStatusResponse.self, from: data)
}
