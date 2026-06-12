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

  // MARK: - Noisy login-shell output (#377)

  // A ShellClient that resolves `gh` via `which` and returns `stdout` for every gh invocation.
  static func ghShell(stdout: String) -> ShellClient {
    ShellClient(
      run: { executableURL, _, _ in
        executableURL.lastPathComponent == "which"
          ? ShellOutput(stdout: "/usr/bin/gh", stderr: "", exitCode: 0)
          : ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { executableURL, _, _, _ in
        guard executableURL.lastPathComponent == "gh" else {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
      }
    )
  }

  @Test func balancedSpansReturnsCleanObjectUnchanged() {
    #expect(GithubCLIOutput.balancedJSONSpans(in: #"{"a":1}"#).map(String.init) == [#"{"a":1}"#])
  }

  @Test func balancedSpansStripBannerBeforeObject() {
    let noisy = "fastfetch banner line\nanother line\n" + #"{"hosts":{}}"#
    #expect(GithubCLIOutput.balancedJSONSpans(in: noisy).map(String.init) == [#"{"hosts":{}}"#])
  }

  @Test func balancedSpansStripBannerBeforeArray() {
    let noisy = "nvm: now using node v20\n" + #"[{"x":1},{"y":2}]"#
    #expect(GithubCLIOutput.balancedJSONSpans(in: noisy).map(String.init) == [#"[{"x":1},{"y":2}]"#])
  }

  @Test func balancedSpansDropTrailingNoise() {
    #expect(GithubCLIOutput.balancedJSONSpans(in: "{\"a\":1}\nshell goodbye").map(String.init) == [#"{"a":1}"#])
  }

  @Test func balancedSpansIgnoreBracesInsideStrings() {
    #expect(GithubCLIOutput.balancedJSONSpans(in: #"{"a":"}]"}"#).map(String.init) == [#"{"a":"}]"}"#])
  }

  @Test func balancedSpansIgnoreEscapedQuoteInsideString() {
    // The escaped quote keeps the scanner in-string, so the brace before it is not a premature close.
    #expect(GithubCLIOutput.balancedJSONSpans(in: #"{"a":"}\""}"#).map(String.init) == [#"{"a":"}\""}"#])
  }

  @Test func balancedSpansReturnBothTopLevelObjectsInOrder() {
    let input = #"{"a":1}"# + "\n" + #"{"b":2}"#
    #expect(GithubCLIOutput.balancedJSONSpans(in: input).map(String.init) == [#"{"a":1}"#, #"{"b":2}"#])
  }

  @Test func balancedSpansSkipUnbalancedOpener() {
    // A stray brace from a verbose login shell must not swallow the real trailing payload.
    let noisy = "chpwd () {\n" + #"[{"databaseId":7}]"#
    #expect(GithubCLIOutput.balancedJSONSpans(in: noisy).map(String.init) == [#"[{"databaseId":7}]"#])
  }

  @Test func balancedSpansReturnEmptyForPureNoise() {
    #expect(GithubCLIOutput.balancedJSONSpans(in: "no json here at all").isEmpty)
  }

  @Test func balancedSpansReturnEmptyForEmptyInput() {
    #expect(GithubCLIOutput.balancedJSONSpans(in: "   \n  ").isEmpty)
  }

  @Test func balancedSpansReturnEmptyForUnterminatedPayload() {
    #expect(GithubCLIOutput.balancedJSONSpans(in: #"{"a":1"#).isEmpty)
  }

  private struct SingleKeyPayload: Decodable, Equatable {
    let value: Int
  }

  @Test func decodeSkipsBracketBearingBannerBeforeObject() throws {
    let noisy = "warn [deprecated]\n" + #"{"value":1}"#
    let decoded = try GithubCLIOutput.decode(SingleKeyPayload.self, from: noisy)
    #expect(decoded == SingleKeyPayload(value: 1))
  }

  @Test func decodeSkipsVersionManagerBannerBeforeObject() throws {
    let noisy = "[nvm] using node v20\n" + #"{"hosts":{}}"#
    let decoded = try GithubCLIOutput.decode(GithubAuthStatusResponse.self, from: noisy)
    #expect(decoded.hosts.isEmpty)
  }

  @Test func activeAccountScansAllHostsForActiveAccount() {
    let response = GithubAuthStatusResponse(hosts: [
      "ghe.acme.com": [.init(active: false, login: "work")],
      "github.com": [.init(active: true, login: "sbertix")],
    ])

    let active = GithubAuthStatusParsing.activeAccount(in: response)

    #expect(active?.host == "github.com")
    #expect(active?.login == "sbertix")
  }

  @Test func activeAccountReturnsNilWhenNoAccountActive() {
    let response = GithubAuthStatusResponse(hosts: [
      "github.com": [.init(active: false, login: "sbertix")]
    ])

    #expect(GithubAuthStatusParsing.activeAccount(in: response) == nil)
  }

  @Test func activeAccountPrefersGithubComWhenMultipleHostsActive() {
    let response = GithubAuthStatusResponse(hosts: [
      "ghe.acme.com": [.init(active: true, login: "work")],
      "github.com": [.init(active: true, login: "sbertix")],
    ])

    let active = GithubAuthStatusParsing.activeAccount(in: response)

    #expect(active?.host == "github.com")
    #expect(active?.login == "sbertix")
  }

  @Test func activeAccountSortsHostsWhenGithubComAbsent() {
    let response = GithubAuthStatusResponse(hosts: [
      "z.example.com": [.init(active: true, login: "zed")],
      "a.example.com": [.init(active: true, login: "ann")],
    ])

    let active = GithubAuthStatusParsing.activeAccount(in: response)

    #expect(active?.host == "a.example.com")
    #expect(active?.login == "ann")
  }

  @Test func authStatusSucceedsDespiteBannerPollutedStdout() async throws {
    let stdout =
      "╭─ fastfetch ─╮\n│ os macOS    │\n╰─────────────╯\n"
      + #"{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"sbertix"}]}}"#
    let client = GithubCLIClient.live(shell: Self.ghShell(stdout: stdout))

    let status = try await client.authStatus()

    #expect(status == GithubAuthStatus(username: "sbertix", host: "github.com"))
  }

  @Test func authStatusReportsActiveAccountOnNonFirstHost() async throws {
    let stdout = #"""
      {"hosts":{"ghe.acme.com":[{"active":false,"login":"work"}],"github.com":[{"active":true,"login":"sbertix"}]}}
      """#
    let client = GithubCLIClient.live(shell: Self.ghShell(stdout: stdout))

    let status = try await client.authStatus()

    #expect(status == GithubAuthStatus(username: "sbertix", host: "github.com"))
  }

  @Test func authStatusThrowsCommandFailedOnNonJsonOutput() async {
    let client = GithubCLIClient.live(shell: Self.ghShell(stdout: "command not found: gh"))

    do {
      _ = try await client.authStatus()
      Issue.record("Expected authStatus to throw")
    } catch GithubCLIError.commandFailed(let message) {
      // No JSON payload -> the shell-pollution hypothesis, not a raw error.
      #expect(message == GithubCLIOutput.noPayloadMessage)
    } catch {
      Issue.record("Unexpected error type: \(error.localizedDescription)")
    }
  }

  @Test func authStatusThrowsUndecodableMessageWhenPayloadParsesButSchemaDiffers() async {
    let client = GithubCLIClient.live(shell: Self.ghShell(stdout: #"{"unexpected":true}"#))

    do {
      _ = try await client.authStatus()
      Issue.record("Expected authStatus to throw")
    } catch GithubCLIError.commandFailed(let message) {
      // Found JSON but it failed to decode -> the version-incompatibility hypothesis.
      #expect(message == GithubCLIOutput.undecodableMessage)
    } catch {
      Issue.record("Unexpected error type: \(error.localizedDescription)")
    }
  }

  @Test func resolveRemoteInfoSucceedsDespiteBannerPollutedStdout() async {
    let stdout =
      "loading shell profile…\n"
      + #"{"name":"upstream-repo","owner":{"login":"upstream-org"},"#
      + #""url":"https://github.com/upstream-org/upstream-repo"}"#
    let client = GithubCLIClient.live(shell: Self.ghShell(stdout: stdout))

    let info = await client.resolveRemoteInfo(URL(fileURLWithPath: "/tmp/repo"))

    #expect(info == GithubRemoteInfo(host: "github.com", owner: "upstream-org", repo: "upstream-repo"))
  }

  @Test func defaultBranchSucceedsDespiteBannerPollutedStdout() async throws {
    let stdout = "conda activate base\n" + #"{"defaultBranchRef":{"name":"main"}}"#
    let client = GithubCLIClient.live(shell: Self.ghShell(stdout: stdout))

    let branch = try await client.defaultBranch(URL(fileURLWithPath: "/tmp/repo"))

    #expect(branch == "main")
  }

  @Test func defaultBranchThrowsCommandFailedOnNonJsonOutput() async {
    let client = GithubCLIClient.live(shell: Self.ghShell(stdout: "not a repo"))

    do {
      _ = try await client.defaultBranch(URL(fileURLWithPath: "/tmp/repo"))
      Issue.record("Expected defaultBranch to throw")
    } catch GithubCLIError.commandFailed {
      // Expected.
    } catch {
      Issue.record("Unexpected error type: \(error.localizedDescription)")
    }
  }

  @Test func latestRunSucceedsDespiteBannerPollutedArray() async throws {
    let stdout =
      "pyenv: version 3.12\n"
      + #"[{"databaseId":7,"workflowName":"CI","name":"CI","displayTitle":"Fix","#
      + #""status":"completed","conclusion":"success","#
      + #""createdAt":"2026-05-01T00:00:00Z","updatedAt":"2026-05-01T00:00:00Z"}]"#
    let client = GithubCLIClient.live(shell: Self.ghShell(stdout: stdout))

    let run = try await client.latestRun(URL(fileURLWithPath: "/tmp/repo"), "main")

    #expect(run?.databaseId == 7)
    #expect(run?.conclusion == "success")
  }

  @Test func latestRunReturnsNilForEmptyOutput() async throws {
    let client = GithubCLIClient.live(shell: Self.ghShell(stdout: ""))

    let run = try await client.latestRun(URL(fileURLWithPath: "/tmp/repo"), "main")

    #expect(run == nil)
  }

  @Test func latestRunReturnsNilForBannerWithNoRuns() async throws {
    // Banner-only stdout with no JSON payload means no runs, not a parse failure.
    let client = GithubCLIClient.live(shell: Self.ghShell(stdout: "shell banner with no json"))

    let run = try await client.latestRun(URL(fileURLWithPath: "/tmp/repo"), "main")

    #expect(run == nil)
  }

  @Test func latestRunThrowsCommandFailedOnPresentButUndecodablePayload() async {
    let client = GithubCLIClient.live(shell: Self.ghShell(stdout: #"[{"databaseId":"not-an-int"}]"#))

    do {
      _ = try await client.latestRun(URL(fileURLWithPath: "/tmp/repo"), "main")
      Issue.record("Expected latestRun to throw on a present-but-undecodable payload")
    } catch GithubCLIError.commandFailed {
      // Expected: a JSON payload that fails to decode is a real parse failure.
    } catch {
      Issue.record("Unexpected error type: \(error.localizedDescription)")
    }
  }

  @Test func latestRunSkipsStrayBraceBannerBeforeRunArray() async throws {
    // A stray unbalanced brace (e.g. a `set -x` trace) must not swallow the real run array.
    let stdout = "+ chpwd () {\n" + #"[{"databaseId":11,"status":"completed"}]"#
    let client = GithubCLIClient.live(shell: Self.ghShell(stdout: stdout))

    let run = try await client.latestRun(URL(fileURLWithPath: "/tmp/repo"), "main")

    #expect(run?.databaseId == 11)
  }

  @Test func latestRunPrefersRealArrayOverLeadingEmptyArrayBanner() async throws {
    // A leading `[]` from shell noise must not shadow the real run list that follows.
    let stdout = "[]\n" + #"[{"databaseId":9,"status":"completed","conclusion":"success"}]"#
    let client = GithubCLIClient.live(shell: Self.ghShell(stdout: stdout))

    let run = try await client.latestRun(URL(fileURLWithPath: "/tmp/repo"), "main")

    #expect(run?.databaseId == 9)
  }

  @Test func authStatusReportsPollutionForBracketNoiseWithoutValidJson() async {
    // Brackets that are not valid JSON (e.g. `[INFO]` log prefixes) are shell noise, not schema drift.
    let client = GithubCLIClient.live(shell: Self.ghShell(stdout: "[INFO] starting up\n[WARN] no config"))

    do {
      _ = try await client.authStatus()
      Issue.record("Expected authStatus to throw")
    } catch GithubCLIError.commandFailed(let message) {
      #expect(message == GithubCLIOutput.noPayloadMessage)
    } catch {
      Issue.record("Unexpected error type: \(error.localizedDescription)")
    }
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
