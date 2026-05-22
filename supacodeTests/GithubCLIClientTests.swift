import ConcurrencyExtras
import Dependencies
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

actor GithubBatchShellProbe {
  struct Snapshot {
    let ghCallCount: Int
    let maxInFlight: Int
    let whichCallCount: Int
    let loginCallCount: Int
  }

  private var ghCallCount = 0
  private var inFlight = 0
  private var maxInFlight = 0
  private var whichCallCount = 0
  private var loginCallCount = 0

  func beginGhCall() -> Int {
    ghCallCount += 1
    inFlight += 1
    if inFlight > maxInFlight {
      maxInFlight = inFlight
    }
    return ghCallCount
  }

  func endGhCall() {
    inFlight -= 1
  }

  func recordWhichCall() {
    whichCallCount += 1
  }

  func recordLoginCall() {
    loginCallCount += 1
  }

  func snapshot() -> Snapshot {
    Snapshot(
      ghCallCount: ghCallCount,
      maxInFlight: maxInFlight,
      whichCallCount: whichCallCount,
      loginCallCount: loginCallCount
    )
  }
}

struct GithubCLIClientTests {
  @Test func batchPullRequestsCapsConcurrencyAtThree() async throws {
    let probe = GithubBatchShellProbe()
    let shell = ShellClient(
      run: { executableURL, arguments, _ in
        if executableURL.lastPathComponent == "which" {
          await probe.recordWhichCall()
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        _ = arguments
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        await probe.recordLoginCall()
        _ = await probe.beginGhCall()
        do {
          try await ContinuousClock().sleep(for: .milliseconds(80))
          let stdout = graphQLResponse(for: arguments)
          await probe.endGhCall()
          return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
        } catch {
          await probe.endGhCall()
          throw error
        }
      }
    )
    let client = GithubCLIClient.live(shell: shell)
    let branches = (0..<100).map { "feature-\($0)" }

    _ = try await client.batchPullRequests("github.com", "khoi", "repo", branches)

    let snapshot = await probe.snapshot()
    #expect(snapshot.ghCallCount == 20)
    #expect(snapshot.maxInFlight == 3)
    #expect(snapshot.whichCallCount == 1)
    #expect(snapshot.loginCallCount == 20)
  }

  @Test func batchPullRequestsThrowsWhenAnyChunkFails() async {
    let probe = GithubBatchShellProbe()
    let shell = ShellClient(
      run: { executableURL, arguments, _ in
        if executableURL.lastPathComponent == "which" {
          await probe.recordWhichCall()
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        _ = arguments
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        await probe.recordLoginCall()
        let callIndex = await probe.beginGhCall()
        if callIndex == 2 {
          await probe.endGhCall()
          throw ShellClientError(
            command: "gh api graphql",
            stdout: "",
            stderr: "boom",
            exitCode: 1
          )
        }
        do {
          try await ContinuousClock().sleep(for: .milliseconds(40))
          let stdout = graphQLResponse(for: arguments)
          await probe.endGhCall()
          return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
        } catch {
          await probe.endGhCall()
          throw error
        }
      }
    )
    let client = GithubCLIClient.live(shell: shell)
    let branches = (0..<30).map { "feature-\($0)" }

    do {
      _ = try await client.batchPullRequests("github.com", "khoi", "repo", branches)
      Issue.record("Expected batchPullRequests to throw")
    } catch let error as GithubCLIError {
      switch error {
      case .commandFailed:
        break
      case .outdated, .unavailable, .gatewayTimeout:
        Issue.record("Unexpected GithubCLIError: \(error.localizedDescription)")
      }
    } catch {
      Issue.record("Unexpected error type: \(error.localizedDescription)")
    }
  }

  @Test func batchPullRequestsRetriesWithoutMergeQueueFieldWhenRejected() async throws {
    // GHES < 3.8 rejects `mergeQueueEntry`; the fetch must retry without it so PR state still loads.
    let probe = GithubBatchShellProbe()
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          await probe.recordWhichCall()
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        await probe.recordLoginCall()
        _ = await probe.beginGhCall()
        let query = arguments.first { $0.hasPrefix("query=") } ?? ""
        if query.contains("mergeQueueEntry") {
          await probe.endGhCall()
          throw ShellClientError(
            command: "gh api graphql",
            stdout: "",
            stderr: "gh: Field 'mergeQueueEntry' doesn't exist on type 'PullRequest'",
            exitCode: 1
          )
        }
        // The field-omitted retry returns a real PR so the test proves PR state survives the fallback.
        let stdout = """
          {"data":{"repository":{"branch0":{"nodes":[{
            "number":42,"title":"Queued","state":"OPEN","additions":1,"deletions":0,"isDraft":false,
            "reviewDecision":null,"updatedAt":"2026-05-01T00:00:00Z",
            "url":"https://github.com/khoi/repo/pull/42","headRefName":"feature-0","baseRefName":"main",
            "headRepository":{"name":"repo","owner":{"login":"khoi"}}
          }]}}}}
          """
        await probe.endGhCall()
        return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
      }
    )
    let client = GithubCLIClient.live(shell: shell)
    let branches = ["feature-0"]

    let result = try await client.batchPullRequests("github.com", "khoi", "repo", branches)

    // PR state survives the field-omitted retry, and the retry fired exactly once.
    #expect(result["feature-0"]?.number == 42)
    #expect(result["feature-0"]?.mergeQueueEntry == nil)
    let snapshot = await probe.snapshot()
    #expect(snapshot.loginCallCount == 2)
  }

  @Test func batchPullRequestsPropagatesNonRejectionErrorMentioningMergeQueue() async {
    // An error that names the field but is not a "doesn't exist" rejection must propagate, not retry.
    let probe = GithubBatchShellProbe()
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          await probe.recordWhichCall()
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, _, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        await probe.recordLoginCall()
        _ = await probe.beginGhCall()
        await probe.endGhCall()
        throw ShellClientError(
          command: "gh api graphql",
          stdout: "",
          stderr: "gh: error fetching mergeQueueEntry: API rate limit exceeded",
          exitCode: 1
        )
      }
    )
    let client = GithubCLIClient.live(shell: shell)
    let branches = ["feature-0"]

    do {
      _ = try await client.batchPullRequests("github.com", "khoi", "repo", branches)
      Issue.record("Expected batchPullRequests to propagate the error")
    } catch GithubCLIError.commandFailed {
      // Expected: the field-omission retry only fires for a "doesn't exist" rejection.
    } catch {
      Issue.record("Unexpected error type: \(error.localizedDescription)")
    }

    let snapshot = await probe.snapshot()
    #expect(snapshot.loginCallCount == 1)
  }

  @Test func batchPullRequestsRetriesOnGatewayTimeoutOnce() async throws {
    let probe = GithubBatchShellProbe()
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          await probe.recordWhichCall()
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        await probe.recordLoginCall()
        let callIndex = await probe.beginGhCall()
        if callIndex == 1 {
          await probe.endGhCall()
          throw ShellClientError(
            command: "gh api graphql",
            stdout: "",
            stderr: "gh: HTTP 504",
            exitCode: 1
          )
        }
        let stdout = graphQLResponse(for: arguments)
        await probe.endGhCall()
        return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
      }
    )
    let client = GithubCLIClient.live(shell: shell)
    let branches = (0..<5).map { "feature-\($0)" }

    let result = try await withDependencies {
      $0.continuousClock = ImmediateClock()
    } operation: {
      try await client.batchPullRequests("github.com", "khoi", "repo", branches)
    }

    #expect(result.isEmpty)
    let snapshot = await probe.snapshot()
    #expect(snapshot.loginCallCount == 2)
  }

  @Test func batchPullRequestsPropagatesGatewayTimeoutAfterOneRetry() async {
    // The retry-once contract: a second consecutive 504 must surface as a
    // `.gatewayTimeout` error rather than spinning forever.
    let probe = GithubBatchShellProbe()
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          await probe.recordWhichCall()
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, _, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        await probe.recordLoginCall()
        _ = await probe.beginGhCall()
        await probe.endGhCall()
        throw ShellClientError(command: "gh api graphql", stdout: "", stderr: "gh: HTTP 504", exitCode: 1)
      }
    )
    let client = GithubCLIClient.live(shell: shell)
    let branches = (0..<5).map { "feature-\($0)" }

    do {
      _ = try await withDependencies {
        $0.continuousClock = ImmediateClock()
      } operation: {
        try await client.batchPullRequests("github.com", "khoi", "repo", branches)
      }
      Issue.record("Expected batchPullRequests to throw after two 504s")
    } catch GithubCLIError.gatewayTimeout {
      // Expected.
    } catch {
      Issue.record("Unexpected error type: \(error.localizedDescription)")
    }

    let snapshot = await probe.snapshot()
    #expect(snapshot.loginCallCount == 2)
  }

  @Test func batchPullRequestsDeduplicatesBeforeChunking() async throws {
    let probe = GithubBatchShellProbe()
    let shell = ShellClient(
      run: { executableURL, arguments, _ in
        if executableURL.lastPathComponent == "which" {
          await probe.recordWhichCall()
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        _ = arguments
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        await probe.recordLoginCall()
        _ = await probe.beginGhCall()
        let stdout = graphQLResponse(for: arguments)
        await probe.endGhCall()
        return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
      }
    )
    let client = GithubCLIClient.live(shell: shell)
    let uniqueBranches = (0..<30).map { "feature-\($0)" }
    let branches = uniqueBranches + ["feature-0", "feature-1", "feature-2", "", ""]

    let result = try await client.batchPullRequests("github.com", "khoi", "repo", branches)

    #expect(result.isEmpty)
    let snapshot = await probe.snapshot()
    #expect(snapshot.ghCallCount == 6)
    #expect(snapshot.whichCallCount == 1)
    #expect(snapshot.loginCallCount == 6)
  }

  @Test func resolveRemoteInfoUsesGhRepoViewAndParsesHost() async {
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        #expect(arguments == ["repo", "view", "--json", "owner,name,url"])
        let stdout = """
          {"name":"upstream-repo","owner":{"login":"upstream-org"},\
          "url":"https://github.com/upstream-org/upstream-repo"}
          """
        return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
      }
    )
    let client = GithubCLIClient.live(shell: shell)

    let info = await client.resolveRemoteInfo(URL(fileURLWithPath: "/tmp/repo"))

    #expect(info == GithubRemoteInfo(host: "github.com", owner: "upstream-org", repo: "upstream-repo"))
  }

  @Test func resolveRemoteInfoReturnsNilWhenGhFails() async {
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in
        throw ShellClientError(command: "gh repo view", stdout: "", stderr: "nope", exitCode: 1)
      }
    )
    let client = GithubCLIClient.live(shell: shell)

    let info = await client.resolveRemoteInfo(URL(fileURLWithPath: "/tmp/repo"))

    #expect(info == nil)
  }

  @Test func mergePullRequestForwardsRepoSlugWhenRemoteProvided() async throws {
    let recordedArguments = LockIsolated<[[String]]>([])
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        recordedArguments.withValue { $0.append(arguments) }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let client = GithubCLIClient.live(shell: shell)
    let remote = GithubRemoteInfo(host: "github.com", owner: "upstream-org", repo: "upstream-repo")

    try await client.mergePullRequest(URL(fileURLWithPath: "/tmp/fork"), remote, 42, .squash)

    #expect(
      recordedArguments.value == [
        ["pr", "merge", "42", "--squash", "--repo", "github.com/upstream-org/upstream-repo"]
      ]
    )
  }

  @Test func mergePullRequestOmitsRepoFlagWhenRemoteMissing() async throws {
    let recordedArguments = LockIsolated<[[String]]>([])
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        recordedArguments.withValue { $0.append(arguments) }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let client = GithubCLIClient.live(shell: shell)

    try await client.mergePullRequest(URL(fileURLWithPath: "/tmp/fork"), nil, 42, .squash)

    #expect(recordedArguments.value == [["pr", "merge", "42", "--squash"]])
  }

  @Test func closePullRequestForwardsRepoSlug() async throws {
    let recordedArguments = LockIsolated<[[String]]>([])
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        recordedArguments.withValue { $0.append(arguments) }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let client = GithubCLIClient.live(shell: shell)
    let remote = GithubRemoteInfo(host: "ghe.acme.com", owner: "team", repo: "repo")

    try await client.closePullRequest(URL(fileURLWithPath: "/tmp/fork"), remote, 7)

    #expect(recordedArguments.value == [["pr", "close", "7", "--repo", "ghe.acme.com/team/repo"]])
  }

  @Test func markPullRequestReadyForwardsRepoSlug() async throws {
    let recordedArguments = LockIsolated<[[String]]>([])
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, arguments, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        recordedArguments.withValue { $0.append(arguments) }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let client = GithubCLIClient.live(shell: shell)
    let remote = GithubRemoteInfo(host: "github.com", owner: "owner", repo: "repo")

    try await client.markPullRequestReady(URL(fileURLWithPath: "/tmp/fork"), remote, 13)

    #expect(recordedArguments.value == [["pr", "ready", "13", "--repo", "github.com/owner/repo"]])
  }

  @Test func executableResolutionIsSingleFlightAndReused() async {
    let probe = GithubBatchShellProbe()
    let shell = ShellClient(
      run: { executableURL, _, _ in
        if executableURL.lastPathComponent == "which" {
          await probe.recordWhichCall()
          return ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, _, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        await probe.recordLoginCall()
        _ = await probe.beginGhCall()
        await probe.endGhCall()
        return ShellOutput(stdout: "gh version 2.79.0", stderr: "", exitCode: 0)
      }
    )
    let client = GithubCLIClient.live(shell: shell)

    let first = await client.isAvailable()
    let second = await client.isAvailable()

    #expect(first)
    #expect(second)
    let snapshot = await probe.snapshot()
    #expect(snapshot.whichCallCount == 1)
    #expect(snapshot.ghCallCount == 2)
    #expect(snapshot.loginCallCount == 2)
  }
}

nonisolated private func graphQLResponse(for arguments: [String]) -> String {
  guard let queryArgument = arguments.first(where: { $0.hasPrefix("query=") }) else {
    return #"{"data":{"repository":{}}}"#
  }
  let query = String(queryArgument.dropFirst("query=".count))
  let aliases = queryAliases(from: query)
  let entries = aliases.map { #""\#($0)":{"nodes":[]}"# }.joined(separator: ",")
  return #"{"data":{"repository":{\#(entries)}}}"#
}

nonisolated private func queryAliases(from query: String) -> [String] {
  guard let regex = try? NSRegularExpression(pattern: #"branch\d+"#) else {
    return []
  }
  let range = NSRange(query.startIndex..<query.endIndex, in: query)
  var seen = Set<String>()
  var aliases: [String] = []
  for match in regex.matches(in: query, range: range) {
    guard let aliasRange = Range(match.range, in: query) else {
      continue
    }
    let alias = String(query[aliasRange])
    if seen.insert(alias).inserted {
      aliases.append(alias)
    }
  }
  return aliases
}
