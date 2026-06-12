import ComposableArchitecture
import Darwin
import Foundation
import SupacodeSettingsShared

struct GithubAuthStatus: Equatable, Sendable {
  let username: String
  let host: String
}

struct GithubAuthStatusResponse: Sendable {
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

// A login shell sources `.zprofile` / `.zlogin` before `gh` runs, so a banner or version-manager
// line can prepend to captured stdout and corrupt the JSON.
enum GithubCLIOutput {
  // No JSON found at all: the likely cause is shell startup output polluting stdout.
  nonisolated static let noPayloadMessage =
    "Could not read GitHub CLI output. Your shell startup files may be printing extra output to stdout."

  // Valid JSON was found but failed to decode: the likely cause is an incompatible gh version.
  nonisolated static let undecodableMessage =
    "Could not parse GitHub CLI output. The installed GitHub CLI version may be incompatible."

  nonisolated private static let logger = SupaLogger("GithubCLI")

  // Every balanced top-level JSON value ({...} or [...]) in `output`, in source order. An opener that
  // never balances (a stray brace from shell noise) is skipped, so leading noise cannot swallow a real
  // payload that follows.
  nonisolated static func balancedJSONSpans(in output: String) -> [Substring] {
    var spans: [Substring] = []
    var searchStart = output.startIndex
    while let start = output[searchStart...].firstIndex(where: { $0 == "{" || $0 == "[" }) {
      let opener = output[start]
      let closer: Character = opener == "{" ? "}" : "]"
      var depth = 0
      var inString = false
      var escaped = false
      var matchedEnd: String.Index?
      var index = start
      scan: while index < output.endIndex {
        let character = output[index]
        switch character {
        case _ where inString && escaped:
          escaped = false
        case "\\" where inString:
          escaped = true
        case "\"" where inString:
          inString = false
        case _ where inString:
          break
        case "\"":
          inString = true
        case opener:
          depth += 1
        case closer:
          depth -= 1
          guard depth == 0 else { break }
          matchedEnd = output.index(after: index)
          break scan
        default:
          break
        }
        index = output.index(after: index)
      }
      guard let end = matchedEnd else {
        // Unbalanced opener (stray bracket in noise): skip it and keep scanning.
        searchStart = output.index(after: start)
        continue
      }
      spans.append(output[start..<end])
      searchStart = end
    }
    return spans
  }

  // Decodes the JSON payload from possibly noisy gh stdout, surfacing a readable error (with the raw
  // output logged) instead of an opaque DecodingError. Throws when no payload is found at all.
  nonisolated static func decode<T: Decodable>(
    _ type: T.Type,
    from output: String,
    decoder: JSONDecoder = JSONDecoder()
  ) throws -> T {
    guard let value = try decodeIfPresent(T.self, from: output, decoder: decoder) else {
      logDecodeFailure(output)
      throw GithubCLIError.commandFailed(noPayloadMessage)
    }
    return value
  }

  // Returns nil when `output` carries no JSON payload at all (e.g. `gh run list` with no runs), and
  // throws only when a payload is present but cannot be decoded. gh prints its JSON after any leading
  // shell noise, so the last decodable span wins.
  nonisolated static func decodeIfPresent<T: Decodable>(
    _ type: T.Type,
    from output: String,
    decoder: JSONDecoder = JSONDecoder()
  ) throws -> T? {
    let spans = balancedJSONSpans(in: output)
    guard !spans.isEmpty else {
      return nil
    }
    var lastDecodingError: Error?
    var sawValidJSON = false
    for span in spans.reversed() {
      let data = Data(span.utf8)
      do {
        return try decoder.decode(T.self, from: data)
      } catch {
        lastDecodingError = error
        if (try? JSONSerialization.jsonObject(with: data)) != nil {
          sawValidJSON = true
        }
      }
    }
    let detail = lastDecodingError.map { "\($0)" } ?? "unknown"
    logger.error("Failed to decode GitHub CLI JSON output: \(snapshot(of: output)) error=\(detail)")
    // Valid JSON that failed to decode points at gh schema drift; otherwise the brackets were noise.
    throw GithubCLIError.commandFailed(sawValidJSON ? undecodableMessage : noPayloadMessage)
  }

  // Logs a length-capped snapshot of the offending output so the user can retrieve it from the log
  // stream without flooding it with a large banner.
  nonisolated static func logDecodeFailure(_ output: String) {
    logger.error("Failed to read GitHub CLI JSON output: \(snapshot(of: output))")
  }

  // Caps the logged output so a large banner does not flood the log stream.
  nonisolated private static func snapshot(of output: String) -> String {
    let limit = 500
    let prefix = output.prefix(limit)
    return prefix.endIndex == output.endIndex ? String(prefix) : "\(prefix)… (truncated)"
  }
}

enum GithubAuthStatusParsing {
  // `hosts` is an unordered dictionary, so prefer github.com and otherwise sort the keys: the result
  // is deterministic even when more than one host has an active account.
  nonisolated static func activeAccount(
    in response: GithubAuthStatusResponse
  ) -> (host: String, login: String)? {
    let orderedHosts = response.hosts.keys.sorted { lhs, rhs in
      if lhs == "github.com" { return true }
      if rhs == "github.com" { return false }
      return lhs < rhs
    }
    for host in orderedHosts {
      if let active = response.hosts[host]?.first(where: { $0.active }) {
        return (host, active.login)
      }
    }
    return nil
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
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try GithubCLIOutput.decode(GithubRepoViewResponse.self, from: output, decoder: decoder)
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
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    // nil payload means no runs; a present-but-undecodable payload still throws.
    let runs = try GithubCLIOutput.decodeIfPresent([GithubWorkflowRun].self, from: output, decoder: decoder)
    return runs?.first
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
    let output: String
    do {
      output = try await runGh(
        shell: shell,
        resolver: resolver,
        arguments: ["repo", "view", "--json", "owner,name,url"],
        repoRoot: repoRoot
      )
    } catch {
      return nil
    }
    // nil contract: decodeIfPresent tolerates leading shell noise and logs a present-but-undecodable
    // payload before throwing, which `try?` collapses back to nil.
    guard
      let response = try? GithubCLIOutput.decodeIfPresent(
        GithubRepoViewRemoteInfoResponse.self,
        from: output
      )
    else {
      return nil
    }
    let host = hostFromRepoViewURL(response.url) ?? "github.com"
    guard !response.owner.login.isEmpty, !response.name.isEmpty else {
      return nil
    }
    return GithubRemoteInfo(
      host: host,
      owner: response.owner.login,
      repo: response.name
    )
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
    let response = try GithubCLIOutput.decode(GithubAuthStatusResponse.self, from: output)
    guard let active = GithubAuthStatusParsing.activeAccount(in: response) else {
      return nil
    }
    return GithubAuthStatus(username: active.login, host: active.host)
  }
}

nonisolated private func deduplicatedBranches(_ branches: [String]) -> [String] {
  var seen = Set<String>()
  return branches.filter { !$0.isEmpty && seen.insert($0).inserted }
}

// Small chunks keep the GraphQL `statusCheckRollup` payload under the gateway's 504 threshold on busy repos.
nonisolated private let batchPullRequestsChunkSize = 5
nonisolated private let batchPullRequestsMaxConcurrentRequests = 3
nonisolated private let batchPullRequestsGatewayRetryBackoff: Duration = .seconds(1)

// Matches `HTTP 504`, `HTTP/1.1 504`, `HTTP/2 504`, etc. on any stderr line.
nonisolated private func isGatewayTimeoutStderr(_ stderr: String) -> Bool {
  stderr.contains(#/\bHTTP(?:/[0-9.]+)?\s+504\b/#)
}

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
  @Dependency(\.continuousClock) var clock

  func runChunkQuery(includeMergeQueueEntry: Bool) async throws -> (output: String, aliasMap: [String: String]) {
    let (query, aliasMap) = makeBatchPullRequestsQuery(
      branches: chunk,
      includeMergeQueueEntry: includeMergeQueueEntry
    )
    let arguments = [
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
    ]
    do {
      let output = try await runGh(shell: shell, resolver: resolver, arguments: arguments, repoRoot: nil)
      return (output, aliasMap)
    } catch GithubCLIError.gatewayTimeout {
      // One retry covers the intermittent cold-start 504 before the next periodic refresh.
      try await clock.sleep(for: batchPullRequestsGatewayRetryBackoff)
      let output = try await runGh(shell: shell, resolver: resolver, arguments: arguments, repoRoot: nil)
      return (output, aliasMap)
    }
  }

  let result: (output: String, aliasMap: [String: String])
  do {
    result = try await runChunkQuery(includeMergeQueueEntry: true)
  } catch let error where isUnknownMergeQueueFieldError(error) {
    // GHES < 3.8 rejects `mergeQueueEntry` and fails the whole request; retry without it so PR
    // state still loads, minus the merge-queue detail that server can't provide anyway.
    result = try await runChunkQuery(includeMergeQueueEntry: false)
  }
  guard !result.output.isEmpty else {
    return (chunkIndex, [:])
  }

  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let response = try GithubCLIOutput.decode(
    GithubGraphQLPullRequestResponse.self,
    from: result.output,
    decoder: decoder
  )
  let prsByBranch = response.pullRequestsByBranch(
    aliasMap: result.aliasMap,
    owner: request.owner,
    repo: request.repo
  )
  return (chunkIndex, prsByBranch)
}

// GHES < 3.8 rejects the `mergeQueueEntry` selection with a "Field 'mergeQueueEntry' doesn't exist"
// GraphQL error. Matching both tokens avoids a needless re-fetch on an error that merely echoes the name.
nonisolated private func isUnknownMergeQueueFieldError(_ error: Error) -> Bool {
  guard case GithubCLIError.commandFailed(let message) = error else {
    return false
  }
  let lowered = message.lowercased()
  return lowered.contains("mergequeueentry") && lowered.contains("doesn't exist")
}

nonisolated private func makeBatchPullRequestsQuery(
  branches: [String],
  includeMergeQueueEntry: Bool
) -> (query: String, aliasMap: [String: String]) {
  // `mergeQueueEntry` is absent on GitHub Enterprise Server < 3.8; omitting it lets PR fetching
  // still succeed there (see the field-rejection fallback in `fetchPullRequestsChunk`).
  let mergeQueueSelection =
    includeMergeQueueEntry ? "mergeQueueEntry { position estimatedTimeToMerge state }" : ""
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
          \(mergeQueueSelection)
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
      if isGatewayTimeoutStderr(shellError.stderr) {
        throw GithubCLIError.gatewayTimeout
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
