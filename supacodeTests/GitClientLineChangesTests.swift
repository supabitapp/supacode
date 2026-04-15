import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

actor LineChangesShellCallStore {
  private(set) var calls: [[String]] = []

  func record(_ arguments: [String]) {
    calls.append(arguments)
  }
}

struct GitClientLineChangesTests {
  @Test func lineChangesUsesShortstatAndParsesOutput() async {
    let store = LineChangesShellCallStore()
    let output = " 1 file changed, 12 insertions(+), 3 deletions(-)\n"
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        return ShellOutput(stdout: output, stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(changes?.added == 12)
    #expect(changes?.removed == 3)
    let calls = await store.calls
    #expect(calls.count == 1)
    let args = calls[0]
    #expect(args.first == "git")
    #expect(args.contains("diff"))
    #expect(args.contains("HEAD"))
    #expect(args.contains("--shortstat"))
    #expect(!args.contains("--numstat"))
  }

  @Test func lineChangesHandlesMissingDeletions() async {
    let output = " 1 file changed, 5 insertions(+)\n"
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: output, stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(changes?.added == 5)
    #expect(changes?.removed == 0)
  }

  @Test func lineChangesParsesShortstatLine() async {
    let output = "1 file changed, 10 insertions(+), 4 deletions(-)\n"
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: output, stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(changes?.added == 10)
    #expect(changes?.removed == 4)
  }

  @Test func lineChangesHandlesEmptyOutput() async {
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "\n", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(changes?.added == 0)
    #expect(changes?.removed == 0)
  }

  @Test func lineChangesSkipsWhenIndexLocked() async throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    let gitDirectory = tempRoot.appending(path: ".git")
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    let headURL = gitDirectory.appending(path: "HEAD")
    try "ref: refs/heads/main\n".write(to: headURL, atomically: true, encoding: .utf8)
    let lockURL = gitDirectory.appending(path: "index.lock")
    try Data().write(to: lockURL)
    let store = LineChangesShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: tempRoot)

    #expect(changes == nil)
    let calls = await store.calls
    #expect(calls.isEmpty)
  }
}
