import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// Drives the bundled `supacode` binary against a fixture socket. The CLI is a
/// separate product with no test target, so a subprocess is the only way to
/// cover its argument parsing and output shape. Serialized because every case
/// waits on fixture replies delivered on the main actor, which concurrent cases
/// would starve.
@MainActor
@Suite(.serialized)
struct WorktreeStatusCLITests {
  private struct Run {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32

    /// Reports the CLI's own error rather than an opaque empty-output mismatch.
    func succeeding(_ sourceLocation: SourceLocation = #_sourceLocation) -> String {
      #expect(exitCode == 0, "CLI failed: \(standardError)", sourceLocation: sourceLocation)
      return standardOutput
    }
  }

  private static let worktreeRows = [
    ["id": "default%20workspace", "status": "main", "focused": "1"],
    ["id": "feature%2Fpinned", "status": "pinned"],
    ["id": "feature%2Funpinned", "status": "unpinned"],
    ["id": "old%2Farchived", "status": "archived"],
  ]

  /// What an app build predating this feature returns: ids and focus, no status.
  private static let legacyRows = worktreeRows.map { $0.filter { $0.key != "status" } }

  @Test(.timeLimit(.minutes(3)))
  func listFiltersAndAppendsStatus() async throws {
    try await withFixture(rows: Self.worktreeRows) { cli, resources, _ in
      let all = try await cli(["worktree", "list"]).succeeding()
      #expect(
        all == """
          default%20workspace
          feature%2Fpinned
          feature%2Funpinned
          old%2Farchived

          """
      )

      let notArchived = try await cli(["worktree", "list", "--not-archived"]).succeeding()
      #expect(
        notArchived == """
          default%20workspace
          feature%2Fpinned
          feature%2Funpinned

          """
      )

      let selected = try await cli(["worktree", "list", "--status", "pinned,archived"]).succeeding()
      #expect(
        selected == """
          feature%2Fpinned
          old%2Farchived

          """
      )

      let annotated = try await cli(["worktree", "list", "--with-status"]).succeeding()
      #expect(
        annotated == """
          default%20workspace\tmain
          feature%2Fpinned\tpinned
          feature%2Funpinned\tunpinned
          old%2Farchived\tarchived

          """
      )

      let focused = try await cli(["worktree", "list", "--focused", "--with-status"]).succeeding()
      #expect(focused == "default%20workspace\tmain\n")

      // One round-trip per invocation; no filter is evaluated twice.
      #expect(resources.value.count == 5)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func listRejectsContradictoryAndUnknownStatusArguments() async throws {
    try await withFixture(rows: Self.worktreeRows) { cli, resources, _ in
      let conflict = try await cli(["worktree", "list", "--status", "pinned", "--not-archived"])
      #expect(conflict.exitCode != 0)
      #expect(conflict.standardError.contains("not both"))

      let unknown = try await cli(["worktree", "list", "--status", "visible"])
      #expect(unknown.exitCode != 0)
      #expect(unknown.standardError.contains("Unknown status 'visible'"))

      // An empty value must not degrade into "no filter at all".
      let empty = try await cli(["worktree", "list", "--status", ""])
      #expect(empty.exitCode != 0)
      #expect(empty.standardError.contains("--status needs at least one"))

      // Validation runs before the query, so the app is never contacted.
      #expect(resources.value.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func statusFiltersFailLoudlyAgainstAnAppThatDoesNotReportStatus() async throws {
    try await withFixture(rows: Self.legacyRows) { cli, _, _ in
      let filtered = try await cli(["worktree", "list", "--not-archived"])
      #expect(filtered.exitCode != 0)
      #expect(filtered.standardError.contains("does not report worktree status"))

      // The default shape predates status, so it must keep working.
      let all = try await cli(["worktree", "list"]).succeeding()
      #expect(
        all == """
          default%20workspace
          feature%2Fpinned
          feature%2Funpinned
          old%2Farchived

          """
      )
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func statusFiltersRejectAMixedResponseButTolerateAnEmptyOne() async throws {
    let mixed = [Self.worktreeRows[0], Self.legacyRows[1]]
    try await withFixture(rows: mixed) { cli, _, _ in
      let filtered = try await cli(["worktree", "list", "--with-status"])
      #expect(filtered.exitCode != 0)
      #expect(filtered.standardError.contains("does not report worktree status"))
    }

    try await withFixture(rows: []) { cli, _, _ in
      let empty = try await cli(["worktree", "list", "--not-archived"])
      #expect(empty.succeeding().isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func withStatusPassesAnUnrecognizedValueThrough() async throws {
    // A newer app may report a status this binary does not know about.
    let rows = [["id": "feature%2Fnew", "status": "hibernated"]]
    try await withFixture(rows: rows) { cli, _, _ in
      let annotated = try await cli(["worktree", "list", "--with-status"]).succeeding()
      #expect(annotated == "feature%2Fnew\thibernated\n")

      // Unknown values are excluded by an explicit filter and kept by --not-archived.
      let selected = try await cli(["worktree", "list", "--status", "unpinned"]).succeeding()
      #expect(selected.isEmpty)
      let kept = try await cli(["worktree", "list", "--not-archived"]).succeeding()
      #expect(kept == "feature%2Fnew\n")
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func statusCommandExplainsAStaleApp() async throws {
    try await withFixture(
      rows: [],
      failWith: "Unknown resource: worktreeStatus",
      resource: "worktreeStatus"
    ) { cli, _, _ in
      let stale = try await cli(["worktree", "status", "-w", "feature%2Fa"])
      #expect(stale.exitCode != 0)
      #expect(stale.standardError.contains("does not report worktree status"))
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func statusCommandPrintsKeyValueLines() async throws {
    let row = ["status": "archived", "archived": "true", "focused": "false"]
    try await withFixture(rows: [row], resource: "worktreeStatus") { cli, resources, parameters in
      let output = try await cli(["worktree", "status", "-w", "old%2Farchived"]).succeeding()
      #expect(
        output == """
          status=archived
          archived=true
          focused=false

          """
      )
      #expect(resources.value == ["worktreeStatus"])
      #expect(parameters.value == [["worktreeID": "old%2Farchived"]])
    }
  }

  // MARK: - Fixture.

  private func withFixture(
    rows: [[String: String]],
    failWith: String? = nil,
    resource expected: String = "worktrees",
    body: (
      _ cli: ([String]) async throws -> Run,
      _ resources: LockIsolated<[String]>,
      _ parameters: LockIsolated<[[String: String]]>
    ) async throws -> Void
  ) async throws {
    // The basename must stay `pid-<live pid>`: `SocketDiscovery.isAlive` rejects
    // any other shape and the CLI would then fall back to the running Supacode.
    let directory = "/tmp/supacode-cli-\(UUID().uuidString)"
    let socketPath = "\(directory)/pid-\(ProcessInfo.processInfo.processIdentifier)"
    let resources = LockIsolated<[String]>([])
    let parameters = LockIsolated<[[String: String]]>([])
    let server = AgentHookSocketServer(socketPathOverride: socketPath)
    try #require(server.socketPath == socketPath)
    server.onQuery = { resource, params, clientFD in
      resources.withValue { $0.append(resource) }
      parameters.withValue { $0.append(params) }
      guard let failWith else {
        AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: rows)
        return
      }
      AgentHookSocketServer.sendCommandResponse(clientFD: clientFD, ok: false, error: failWith)
    }
    defer {
      server.shutdown()
      try? FileManager.default.removeItem(atPath: directory)
    }

    try await body(
      { try await Self.runCLI(arguments: $0, socketPath: socketPath) },
      resources,
      parameters
    )
    #expect(resources.value.allSatisfy { $0 == expected })
  }

  private static func runCLI(arguments: [String], socketPath: String) async throws -> Run {
    let executableURL = try #require(Bundle.main.resourceURL?.appending(path: "bin/supacode"))
    try #require(FileManager.default.fileExists(atPath: executableURL.path(percentEncoded: false)))
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = executableURL
    // Well under the CLI's default, but generous enough that a busy main actor
    // (the fixture answers on it) does not read as a timeout. `.timeLimit` is
    // the real backstop against a fixture that never answers.
    process.arguments = arguments + ["--timeout", "30"]
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["SUPACODE_SOCKET_PATH": socketPath],
      uniquingKeysWith: { _, fixture in fixture }
    )
    process.standardOutput = output
    process.standardError = error

    try await process.runToExit()

    return Run(
      standardOutput: String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      standardError: String(bytes: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      exitCode: process.terminationStatus
    )
  }
}
