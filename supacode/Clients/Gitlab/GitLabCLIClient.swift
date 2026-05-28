import ComposableArchitecture
import Darwin
import Foundation
import SupacodeSettingsShared

struct GitLabCLIClient: Sendable {
  var resolveRemoteInfo: @Sendable (URL) async -> ForgeRemoteInfo?
  var batchMergeRequests: @Sendable (String, String, String, [String]) async throws -> [String: GitLabMergeRequest]
  var isAvailable: @Sendable () async -> Bool
  var authStatus: @Sendable () async throws -> GitLabAuthStatus?
}

extension GitLabCLIClient: DependencyKey {
  static let liveValue = live()

  static func live(shell: ShellClient = .liveValue) -> GitLabCLIClient {
    let resolver = GitLabCLIExecutableResolver()
    return GitLabCLIClient(
      resolveRemoteInfo: resolveRemoteInfoFetcher(shell: shell, resolver: resolver),
      batchMergeRequests: batchMergeRequestsFetcher(shell: shell, resolver: resolver),
      isAvailable: isAvailableFetcher(shell: shell, resolver: resolver),
      authStatus: authStatusFetcher(shell: shell, resolver: resolver)
    )
  }

  static let testValue = GitLabCLIClient(
    resolveRemoteInfo: { _ in nil },
    batchMergeRequests: { _, _, _, _ in [:] },
    isAvailable: { true },
    authStatus: { GitLabAuthStatus(username: "testuser", host: "gitlab.com") }
  )
}

extension DependencyValues {
  var gitlabCLI: GitLabCLIClient {
    get { self[GitLabCLIClient.self] }
    set { self[GitLabCLIClient.self] = newValue }
  }
}

private actor GitLabCLIExecutableResolver {
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
    if let executableURL = await locateExecutableURL(shell: shell, useLoginShell: false) {
      return executableURL
    }
    if let executableURL = await locateExecutableURL(shell: shell, useLoginShell: true) {
      return executableURL
    }
    throw GitLabCLIError.unavailable
  }

  private func locateExecutableURL(shell: ShellClient, useLoginShell: Bool) async -> URL? {
    let whichURL = URL(fileURLWithPath: "/usr/bin/which")
    do {
      let output: String
      if useLoginShell {
        output = try await shell.runLogin(whichURL, ["glab"], nil, log: false).stdout
      } else {
        output = try await shell.run(whichURL, ["glab"], nil).stdout
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

// `glab repo view --output json` returns name + namespace + web_url.
private nonisolated struct GitLabRepoViewResponse: Decodable, Sendable {
  let name: String?
  let path: String?
  let pathWithNamespace: String?
  let webUrl: String?

  private enum CodingKeys: String, CodingKey {
    case name
    case path
    case pathWithNamespace = "path_with_namespace"
    case webUrl = "web_url"
  }
}

nonisolated private func resolveRemoteInfoFetcher(
  shell: ShellClient,
  resolver: GitLabCLIExecutableResolver
) -> @Sendable (URL) async -> ForgeRemoteInfo? {
  { repoRoot in
    do {
      let output = try await runGlab(
        shell: shell,
        resolver: resolver,
        arguments: ["repo", "view", "--output", "json"],
        repoRoot: repoRoot
      )
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        return nil
      }
      let response = try JSONDecoder().decode(GitLabRepoViewResponse.self, from: Data(trimmed.utf8))
      guard let pathWithNamespace = response.pathWithNamespace, !pathWithNamespace.isEmpty else {
        return nil
      }
      let host = hostFromWebURL(response.webUrl) ?? "gitlab.com"
      let segments = pathWithNamespace.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
      guard let repo = segments.last, segments.count >= 2 else {
        return nil
      }
      let owner = segments.dropLast().joined(separator: "/")
      return ForgeRemoteInfo(forge: .gitlab, host: host, owner: owner, repo: repo)
    } catch {
      return nil
    }
  }
}

nonisolated private func hostFromWebURL(_ urlString: String?) -> String? {
  guard let urlString, !urlString.isEmpty,
    let url = URL(string: urlString),
    let host = url.host,
    !host.isEmpty
  else {
    return nil
  }
  return host
}

nonisolated private let batchMergeRequestsPageSize = 50

nonisolated private func batchMergeRequestsFetcher(
  shell: ShellClient,
  resolver: GitLabCLIExecutableResolver
) -> @Sendable (String, String, String, [String]) async throws -> [String: GitLabMergeRequest] {
  { host, owner, repo, branches in
    let dedupedBranches = deduplicatedBranches(branches)
    guard !dedupedBranches.isEmpty else {
      return [:]
    }
    let fullPath = "\(owner)/\(repo)"
    let (query, branchListLiteral) = makeBatchMergeRequestsQuery(branches: dedupedBranches)
    let arguments = [
      "api",
      "graphql",
      "--hostname",
      host,
      "-f",
      "query=\(query)",
      "-f",
      "fullPath=\(fullPath)",
      "-f",
      "sourceBranches=\(branchListLiteral)",
    ]
    let output = try await runGlab(shell: shell, resolver: resolver, arguments: arguments, repoRoot: nil)
    guard !output.isEmpty else {
      return [:]
    }
    let data = Data(output.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(GitLabGraphQLMergeRequestResponse.self, from: data)
    return response.mergeRequestsBySourceBranch()
  }
}

// GitLab GraphQL: `Project.mergeRequests(sourceBranches: [String])` returns MRs grouped under the
// project. v1 fetches open MRs only — merged-state display is a v2 nicety.
nonisolated private func makeBatchMergeRequestsQuery(
  branches: [String]
) -> (query: String, branchListLiteral: String) {
  // GitLab `--field` doesn't natively encode arrays. The query takes `[String!]!` and we pass it as a
  // literal JSON array string via `-f` (string), which glab will pass through as-is when the param
  // type matches. Simpler than maintaining variable-by-variable encoding.
  let escaped = branches.map { "\"\(escapeGraphQLString($0))\"" }.joined(separator: ",")
  let branchListLiteral = "[\(escaped)]"
  let query = """
    query($fullPath: ID!) {
      project(fullPath: $fullPath) {
        mergeRequests(sourceBranches: \(branchListLiteral), state: opened, sort: UPDATED_DESC, first: \(batchMergeRequestsPageSize)) {
          nodes {
            iid
            title
            state
            draft
            webUrl
            updatedAt
            sourceBranch
            targetBranch
            diffStatsSummary {
              additions
              deletions
            }
            author {
              username
            }
            headPipeline {
              status
            }
          }
        }
      }
    }
    """
  return (query, branchListLiteral)
}

nonisolated private func escapeGraphQLString(_ value: String) -> String {
  value
    .replacing("\\", with: "\\\\")
    .replacing("\"", with: "\\\"")
    .replacing("\n", with: "\\n")
    .replacing("\r", with: "\\r")
    .replacing("\t", with: "\\t")
}

nonisolated private func deduplicatedBranches(_ branches: [String]) -> [String] {
  var seen = Set<String>()
  return branches.filter { !$0.isEmpty && seen.insert($0).inserted }
}

nonisolated private func isAvailableFetcher(
  shell: ShellClient,
  resolver: GitLabCLIExecutableResolver
) -> @Sendable () async -> Bool {
  {
    do {
      _ = try await runGlab(
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
  resolver: GitLabCLIExecutableResolver
) -> @Sendable () async throws -> GitLabAuthStatus? {
  {
    // `glab auth status` prints `✓ Logged in to gitlab.com as USERNAME (...)` to stderr in
    // human-readable form. There's no `--json` flag as of glab 1.x, so parse the textual output.
    let output: String
    do {
      output = try await runGlab(
        shell: shell,
        resolver: resolver,
        arguments: ["auth", "status"],
        repoRoot: nil,
        captureStderr: true
      )
    } catch GitLabCLIError.commandFailed(let message) {
      // glab returns exit 1 when not authenticated, with the message in stderr. Fall through and
      // try to parse — if nothing matches we return nil.
      output = message
    }
    return parseGlabAuthStatus(output)
  }
}

// Matches `Logged in to <host> as <user>` (with optional preceding glyph).
nonisolated func parseGlabAuthStatus(_ output: String) -> GitLabAuthStatus? {
  let pattern = #/Logged in to\s+([^\s]+)\s+as\s+([^\s\(]+)/#
  guard let match = output.firstMatch(of: pattern) else {
    return nil
  }
  let host = String(match.1)
  let username = String(match.2)
  guard !host.isEmpty, !username.isEmpty else {
    return nil
  }
  return GitLabAuthStatus(username: username, host: host)
}

nonisolated private func runGlab(
  shell: ShellClient,
  resolver: GitLabCLIExecutableResolver,
  arguments: [String],
  repoRoot: URL?,
  captureStderr: Bool = false
) async throws -> String {
  let command = (["glab"] + arguments).joined(separator: " ")
  do {
    let executableURL = try await resolver.executableURL(shell: shell)
    do {
      let result = try await shell.runLogin(executableURL, arguments, repoRoot, log: false)
      return captureStderr && result.stdout.isEmpty ? result.stderr : result.stdout
    } catch {
      guard shouldRetryGlabExecution(after: error) else {
        throw error
      }
      await resolver.invalidate()
      let executableURL = try await resolver.executableURL(shell: shell)
      let result = try await shell.runLogin(executableURL, arguments, repoRoot, log: false)
      return captureStderr && result.stdout.isEmpty ? result.stderr : result.stdout
    }
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

nonisolated private func shouldRetryGlabExecution(after error: Error) -> Bool {
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
