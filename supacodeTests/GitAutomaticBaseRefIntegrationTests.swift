import Foundation
import Testing

@testable import supacode

struct GitAutomaticBaseRefIntegrationTests {
  @Test func fallsBackToLocalHeadForBareRepo() async throws {
    let tempRoot = URL(filePath: "/tmp", directoryHint: .isDirectory)
    let id = UUID().uuidString
    let bareURL = tempRoot.appending(
      path: "supacode-bare-\(id).git",
      directoryHint: URL.DirectoryHint.isDirectory
    )
    let workURL = tempRoot.appending(
      path: "supacode-work-\(id)",
      directoryHint: URL.DirectoryHint.isDirectory
    )
    defer {
      try? FileManager.default.removeItem(at: bareURL)
      try? FileManager.default.removeItem(at: workURL)
    }

    try await runGit(["init", workURL.path(percentEncoded: false)])
    try await runGit(["-C", workURL.path(percentEncoded: false), "config", "user.email", "test@example.com"])
    try await runGit(["-C", workURL.path(percentEncoded: false), "config", "user.name", "Test User"])

    let readmeURL = workURL.appending(path: "README.md")
    try "hello".write(to: readmeURL, atomically: true, encoding: .utf8)
    try await runGit(["-C", workURL.path(percentEncoded: false), "add", "README.md"])
    try await runGit(["-C", workURL.path(percentEncoded: false), "commit", "-m", "init"])
    try await runGit(["-C", workURL.path(percentEncoded: false), "branch", "-M", "main"])

    try await runGit(["init", "--bare", bareURL.path(percentEncoded: false)])
    try await runGit([
      "-C", workURL.path(percentEncoded: false),
      "remote", "add", "origin", bareURL.path(percentEncoded: false),
    ])
    try await runGit(["-C", workURL.path(percentEncoded: false), "push", "-u", "origin", "main"])
    try await runGit(["--git-dir", bareURL.path(percentEncoded: false), "symbolic-ref", "HEAD", "refs/heads/main"])

    let baseRef = await GitClient().automaticWorktreeBaseRef(for: bareURL)
    #expect(baseRef == "main")
  }
}

private struct GitCommandError: Error {
  let output: String
}

@discardableResult
private func runGit(_ arguments: [String]) async throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = arguments
  // Hermetic git: the user's global config must not leak in (gpg signing
  // in particular fails under concurrent test load).
  process.environment = ProcessInfo.processInfo.environment.merging([
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_SYSTEM": "/dev/null",
  ]) { _, override in override }
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  try await process.runToExit()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  let output = String(data: data, encoding: .utf8) ?? ""
  if process.terminationStatus != 0 {
    throw GitCommandError(output: output)
  }
  return output
}
