import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// Regression coverage for socket liveness under sandboxed callers: probing
/// the owning PID with `kill(pid, 0)` fails with EPERM when the caller cannot
/// signal the Supacode app, and the CLI must treat that as alive; only ESRCH
/// proves the PID is gone. Fixtures use `pid-1`: launchd is root-owned, so
/// probing it fails with EPERM for the test runner exactly like a sandboxed
/// probe against the app. The CLI is a separate product with no test target,
/// so a subprocess is the only way to cover this.
@MainActor
@Suite(.serialized)
struct SocketLivenessCLITests {
  @Test(.timeLimit(.minutes(3)))
  func envSocketOwnedByUnsignalablePidIsTrusted() async throws {
    let directory = "/tmp/supacode-cli-\(UUID().uuidString)"
    let socketPath = "\(directory)/pid-1"
    let queried = LockIsolated(false)
    let server = AgentHookSocketServer(socketPathOverride: socketPath)
    defer {
      server.shutdown()
      try? FileManager.default.removeItem(atPath: directory)
    }
    try #require(server.socketPath == socketPath)
    server.onQuery = { _, _, clientFD in
      queried.setValue(true)
      AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: [["id": "wt%2Fone"]])
    }

    let run = try await Self.runCLI(
      arguments: ["worktree", "list", "--timeout", "30"],
      environment: ["SUPACODE_SOCKET_PATH": socketPath]
    )

    #expect(run.exitCode == 0, "CLI failed: \(run.standardError)")
    #expect(queried.value)
    #expect(run.standardOutput == "wt%2Fone\n")
  }

  @Test(.timeLimit(.minutes(3)))
  func socketListingUsesEPermAwareLiveness() async throws {
    // `supacode socket` enumerates the real per-uid directory read-only, so
    // fixture entries are additive and ignore any concurrently running app.
    // Caveat: a Supacode build predating the EPERM-aware prune sweeping the
    // directory mid-test would delete `pid-1` and flake this test.
    let directory = "/tmp/supacode-\(getuid())"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let livePid = "pid-\(ProcessInfo.processInfo.processIdentifier)"
    let fixtures = ["pid-1", "pid-999999999", "pid-abc", "pid-0", "garbage", livePid]
    for fixture in fixtures {
      // Pre-clean leftovers from a crashed prior run: nothing else ever
      // removes a stale `pid-1`, since the EPERM-aware prune keeps it.
      try? FileManager.default.removeItem(atPath: "\(directory)/\(fixture)")
      try #require(FileManager.default.createFile(atPath: "\(directory)/\(fixture)", contents: nil))
    }
    defer {
      for fixture in fixtures {
        try? FileManager.default.removeItem(atPath: "\(directory)/\(fixture)")
      }
    }

    let run = try await Self.runCLI(arguments: ["socket"], environment: [:])

    #expect(run.exitCode == 0, "CLI failed: \(run.standardError)")
    let listed = run.standardOutput.split(separator: "\n").map(String.init)
    #expect(listed.contains("\(directory)/pid-1"))
    #expect(listed.contains("\(directory)/\(livePid)"))
    #expect(!listed.contains("\(directory)/pid-999999999"))
    #expect(!listed.contains("\(directory)/pid-abc"))
    #expect(!listed.contains("\(directory)/pid-0"))
    #expect(!listed.contains("\(directory)/garbage"))
  }

  // MARK: - Helpers.

  private struct Run {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32
  }

  private static func runCLI(arguments: [String], environment: [String: String]) async throws -> Run {
    let executableURL = try #require(Bundle.main.resourceURL?.appending(path: "bin/supacode"))
    try #require(FileManager.default.fileExists(atPath: executableURL.path(percentEncoded: false)))
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(
      environment,
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
