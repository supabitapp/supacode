import Foundation
import Testing

@testable import supacode

struct GitWtWorktreeEntryTests {
  @Test func decodesIsBare() throws {
    let json = """
      [
        {"branch":"(bare)","path":"/tmp/repo.git","head":"","is_bare":true},
        {"branch":"main","path":"/tmp/worktree","head":"abc123","is_bare":false}
      ]
      """
    let data = Data(json.utf8)
    let entries = try JSONDecoder().decode([GitWtWorktreeEntry].self, from: data)
    #expect(entries.count == 2)
    #expect(entries[0].isBare)
    #expect(entries[1].isBare == false)
  }

  @Test func filtersBareEntries() {
    let entries = [
      GitWtWorktreeEntry(branch: "(bare)", path: "/tmp/repo.git", head: "", isBare: true),
      GitWtWorktreeEntry(branch: "main", path: "/tmp/worktree", head: "abc123", isBare: false),
    ]
    let filtered = entries.filter { !$0.isBare }
    #expect(filtered.count == 1)
    #expect(filtered.first?.branch == "main")
  }

  // The bundled `wt` is patched at build time (see `scripts/embed-runtime-assets.sh`);
  // the build guards only prove the patch applies, so exercise the patched behavior
  // end to end: a broken inner worktree must not report a duplicate path (#616).
  @Test func patchedWtDoesNotReportDuplicatePathForBrokenInnerWorktree() async throws {
    let repoRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()  // supacodeTests
      .deletingLastPathComponent()  // repo root
    let wtSource = repoRoot.appending(path: "Resources/git-wt/wt")
    let patch = repoRoot.appending(path: "patches/git-wt/git-wt-canonical-worktree-path.patch")
    try #require(FileManager.default.fileExists(atPath: wtSource.path(percentEncoded: false)))
    try #require(FileManager.default.fileExists(atPath: patch.path(percentEncoded: false)))

    let container = URL(filePath: NSTemporaryDirectory())
      .appending(path: "supacode-wt-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }

    // Patch a fresh copy of `wt` exactly as the build does.
    let patchedWt = container.appending(path: "wt")
    try FileManager.default.copyItem(at: wtSource, to: patchedWt)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: patchedWt.path(percentEncoded: false))
    _ = try await Self.run(
      "/usr/bin/git",
      ["apply", "-p1", patch.path(percentEncoded: false)],
      cwd: container,
      extraEnvironment: ["GIT_DIR": "/dev/null"]
    )

    // A repo whose inner worktree lost its `.git` link (the #616 shape).
    let repo = container.appending(path: "main", directoryHint: .isDirectory)
    let repoPath = repo.path(percentEncoded: false)
    _ = try await Self.run("/usr/bin/git", ["init", repoPath])
    _ = try await Self.run("/usr/bin/git", ["-C", repoPath, "commit", "--allow-empty", "-m", "init"])
    _ = try await Self.run(
      "/usr/bin/git", ["-C", repoPath, "worktree", "add", "\(repoPath)/.inner", "-b", "inner"]
    )
    try FileManager.default.removeItem(at: repo.appending(path: ".inner/.git"))

    let json = try await Self.run(patchedWt.path(percentEncoded: false), ["ls", "--json"], cwd: repo)
    let entries = try JSONDecoder().decode([GitWtWorktreeEntry].self, from: Data(json.utf8))
    let paths = entries.map(\.path)
    // Both worktrees must be listed; a regression that dropped one would make the
    // no-duplicate check pass trivially.
    #expect(paths.count == 2, "expected the main and inner worktrees, got \(paths)")
    #expect(Set(paths).count == paths.count, "wt reported a duplicate worktree path: \(paths)")
  }

  /// Runs a process to completion and returns its stdout+stderr. Git calls stay
  /// hermetic so the user's global config can't leak in.
  private static func run(
    _ launchPath: String,
    _ arguments: [String],
    cwd: URL? = nil,
    extraEnvironment: [String: String] = [:]
  ) async throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: launchPath)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd }
    process.environment = ProcessInfo.processInfo.environment
      .merging([
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_AUTHOR_NAME": "Test User",
        "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test User",
        "GIT_COMMITTER_EMAIL": "test@example.com",
      ]) { _, new in new }
      .merging(extraEnvironment) { _, new in new }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try await process.runToExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(bytes: data, encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
      throw GitWtProcessError(command: "\(launchPath) \(arguments.joined(separator: " "))", output: output)
    }
    return output
  }
}

private struct GitWtProcessError: Error {
  let command: String
  let output: String
}
