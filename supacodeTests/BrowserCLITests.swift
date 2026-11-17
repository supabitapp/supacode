import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct BrowserCLITests {
  private struct Run {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32
  }

  private static let pageOutput = "--- page ab12cd ---\nclicked button \"Save\"\n--- end ab12cd ---"

  @Test(.timeLimit(.minutes(3)))
  func anActionSendsOneStepAndPrintsThePageOutput() async throws {
    try await withFixture(reply: ["output": Self.pageOutput]) { cli, requests in
      let run = try await cli(["browser", "click", "e12", "-t", "TAB-1", "--quiet"], nil)
      #expect(run.exitCode == 0, "CLI failed: \(run.standardError)")
      #expect(run.standardOutput == Self.pageOutput + "\n")
      let request = try #require(requests.value.first)
      #expect(request.tabID == "TAB-1")
      #expect(request.quiet)
      #expect(request.steps == [BrowserAutomationStep(verb: .click, target: "e12")])
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func aBatchReadsOneStepPerLineFromStandardInput() async throws {
    let script = """
      # sign in
      fill 'role=textbox[name="Email"]' "ada@example.com"
      press Enter
      wait --text "Welcome back" --timeout 3

      snapshot --full
      """
    try await withFixture(reply: ["output": Self.pageOutput]) { cli, requests in
      let run = try await cli(["browser", "batch", "-t", "TAB-1"], script)
      #expect(run.exitCode == 0, "CLI failed: \(run.standardError)")
      let request = try #require(requests.value.first)
      #expect(!request.quiet)
      #expect(
        request.steps == [
          BrowserAutomationStep(verb: .fill, target: "role=textbox[name=\"Email\"]", text: "ada@example.com"),
          BrowserAutomationStep(verb: .press, key: "Enter"),
          BrowserAutomationStep(verb: .wait, text: "Welcome back", hidden: false, timeout: 3),
          BrowserAutomationStep(verb: .snapshot, full: true),
        ])
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func aBadBatchLineFailsBeforeTheAppIsContacted() async throws {
    try await withFixture(reply: [:]) { cli, requests in
      let unknown = try await cli(["browser", "batch"], "click e1\nhover e2\n")
      #expect(unknown.exitCode != 0)
      #expect(unknown.standardError.contains("Line 2:"))

      let targeted = try await cli(["browser", "batch"], "click e1 -t TAB-2\n")
      #expect(targeted.exitCode != 0)
      #expect(targeted.standardError.contains("pass -t and -w to `batch`"))

      let empty = try await cli(["browser", "batch"], "# nothing\n")
      #expect(empty.exitCode != 0)
      #expect(empty.standardError.contains("No steps on stdin."))
      #expect(requests.value.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func openPrintsOnlyTheNewTabID() async throws {
    try await withFixture(reply: ["id": "NEW-TAB"]) { cli, requests in
      let run = try await cli(["browser", "open", "localhost:3000", "--background"], nil)
      #expect(run.exitCode == 0, "CLI failed: \(run.standardError)")
      #expect(run.standardOutput == "NEW-TAB\n")
      let request = try #require(requests.value.first)
      #expect(request.newTab == .init(url: "localhost:3000", background: true))
      #expect(request.steps.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func aFailedStepPrintsThePageOutputAndExitsNonZero() async throws {
    let reply = ["output": Self.pageOutput, "error": "The browser command failed. The reason is in the page output."]
    try await withFixture(reply: reply) { cli, _ in
      let run = try await cli(["browser", "click", "e12"], nil)
      #expect(run.exitCode != 0)
      #expect(run.standardOutput == Self.pageOutput + "\n")
      #expect(run.standardError.contains("The browser command failed."))
    }
  }

  @Test(.timeLimit(.minutes(3)))
  func theGuideFitsItsBudgetAndNeedsNoApp() async throws {
    try await withFixture(reply: [:]) { cli, requests in
      let run = try await cli(["browser", "guide"], nil)
      #expect(run.exitCode == 0)
      #expect(run.standardOutput.contains("supacode browser batch"))
      #expect(run.standardOutput.utf8.count <= 4096)
      #expect(requests.value.isEmpty)
    }
  }

  private func withFixture(
    reply: [String: String],
    body: (
      _ cli: ([String], String?) async throws -> Run,
      _ requests: LockIsolated<[BrowserAutomationRequest]>
    ) async throws -> Void
  ) async throws {
    let directory = "/tmp/supacode-cli-\(UUID().uuidString)"
    let socketPath = "\(directory)/pid-\(ProcessInfo.processInfo.processIdentifier)"
    let requests = LockIsolated<[BrowserAutomationRequest]>([])
    let server = AgentHookSocketServer(socketPathOverride: socketPath)
    try #require(server.socketPath == socketPath)
    server.onQuery = { resource, params, clientFD in
      if resource == "browser", let request = params["request"].flatMap({ try? BrowserAutomationRequest(json: $0) }) {
        requests.withValue { $0.append(request) }
      }
      AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: [reply])
    }
    defer {
      server.shutdown()
      try? FileManager.default.removeItem(atPath: directory)
    }
    try await body({ try await Self.runCLI(arguments: $0, input: $1, socketPath: socketPath) }, requests)
  }

  private static func runCLI(arguments: [String], input: String?, socketPath: String) async throws -> Run {
    let executableURL = try #require(Bundle.main.resourceURL?.appending(path: "bin/supacode"))
    try #require(FileManager.default.fileExists(atPath: executableURL.path(percentEncoded: false)))
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    let standardInput = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["SUPACODE_SOCKET_PATH": socketPath],
      uniquingKeysWith: { _, fixture in fixture }
    )
    process.standardOutput = output
    process.standardError = error
    process.standardInput = standardInput
    standardInput.fileHandleForWriting.write(Data((input ?? "").utf8))
    try standardInput.fileHandleForWriting.close()

    try await process.runToExit()

    return Run(
      standardOutput: String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      standardError: String(bytes: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      exitCode: process.terminationStatus
    )
  }
}
