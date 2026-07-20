import Foundation
import OrderedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct WorktreeListVisibilityTests {
  private let repositoryID: Repository.ID = "/tmp/repo"

  @Test func sidebarOwnsVisibilityForEveryBucketAndEmptySections() {
    var sidebar = SidebarState()
    sidebar.sections[repositoryID] = .init(
      buckets: [
        .pinned: .init(),
        .unpinned: .init(),
        .archived: .init(),
      ]
    )
    sidebar.insert(worktree: "pinned", in: repositoryID, bucket: .pinned)
    sidebar.insert(worktree: "unpinned", in: repositoryID, bucket: .unpinned)
    sidebar.insert(
      worktree: "archived",
      in: repositoryID,
      bucket: .archived,
      item: .init(archivedAt: Date(timeIntervalSince1970: 1))
    )

    #expect(sidebar.visibility(of: WorktreeID(repositoryID.rawValue), in: repositoryID) == .visible)
    #expect(sidebar.visibility(of: "pinned", in: repositoryID) == .visible)
    #expect(sidebar.visibility(of: "unpinned", in: repositoryID) == .visible)
    #expect(sidebar.visibility(of: "archived", in: repositoryID) == .archived)
  }

  @Test func queryFieldsEncodeIDsAndReportFocusedDefaultWorkspace() {
    let worktreeID: Worktree.ID = "/tmp/repo/default workspace"

    let fields = WorktreeListQueryResponse.fields(
      repositoryID: repositoryID,
      worktreeID: worktreeID,
      sidebar: SidebarState(),
      selectedWorktreeID: worktreeID
    )

    #expect(fields["id"] == "%2Ftmp%2Frepo%2Fdefault%20workspace")
    #expect(fields["visibility"] == "visible")
    #expect(fields["focused"] == "1")
  }

  @Test func cliListPreservesDefaultOutputAndExposesVisibility() async throws {
    let socketPath = "/tmp/supacode-cli-\(UUID().uuidString)/pid-\(ProcessInfo.processInfo.processIdentifier)"
    let server = AgentHookSocketServer(socketPathOverride: socketPath)
    server.onQuery = { resource, _, clientFD in
      #expect(resource == "worktrees")
      AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: Self.queryItems)
    }
    defer { server.shutdown() }

    let defaultOutput = try await runCLI(arguments: ["worktree", "list"], socketPath: socketPath)
    #expect(
      defaultOutput == """
        default%20workspace
        feature%2Fpinned
        feature%2Funpinned
        old%2Farchived

        """
    )

    let visibleOutput = try await runCLI(
      arguments: ["worktree", "list", "--visible"],
      socketPath: socketPath
    )
    #expect(
      visibleOutput == """
        default%20workspace
        feature%2Fpinned
        feature%2Funpinned

        """
    )

    let visibilityOutput = try await runCLI(
      arguments: ["worktree", "list", "--with-visibility"],
      socketPath: socketPath
    )
    #expect(
      visibilityOutput == """
        default%20workspace\tvisible
        feature%2Fpinned\tvisible
        feature%2Funpinned\tvisible
        old%2Farchived\tarchived

        """
    )

    let focusedOutput = try await runCLI(
      arguments: ["worktree", "list", "--focused", "--with-visibility"],
      socketPath: socketPath
    )
    #expect(focusedOutput == "default%20workspace\tvisible\n")
  }

  private func runCLI(arguments: [String], socketPath: String) async throws -> String {
    let executableURL = try #require(Bundle.main.resourceURL?.appending(path: "bin/supacode"))
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["SUPACODE_SOCKET_PATH": socketPath],
      uniquingKeysWith: { _, fixture in fixture }
    )
    process.standardOutput = output
    process.standardError = error

    try await process.runToExit()

    let standardOutput =
      String(
        bytes: output.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    let standardError =
      String(
        bytes: error.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    #expect(process.terminationStatus == 0, "CLI failed: \(standardError)")
    return standardOutput
  }

  private static let queryItems = [
    ["id": "default%20workspace", "visibility": "visible", "focused": "1"],
    ["id": "feature%2Fpinned", "visibility": "visible"],
    ["id": "feature%2Funpinned", "visibility": "visible"],
    ["id": "old%2Farchived", "visibility": "archived"],
  ]
}
