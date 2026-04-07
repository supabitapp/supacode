import Foundation
import Testing

@testable import supacode

actor ShellCallStore {
  private(set) var calls: [[String]] = []

  func record(_ arguments: [String]) {
    calls.append(arguments)
  }
}

struct GitClientBranchRefsTests {
  @Test func branchRefsIncludesLocalAndUpstreamRefs() async throws {
    let store = ShellCallStore()
    let output = """
      feature\torigin/feature
      main\t
      bugfix\torigin/bugfix
      """
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        return ShellOutput(stdout: output, stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")

    let refs = try await client.branchRefs(for: repoRoot)

    let expected = ["bugfix", "feature", "main", "origin/bugfix", "origin/feature"]
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    #expect(refs == expected)
    let calls = await store.calls
    #expect(calls.count == 1)
    let args = calls[0]
    #expect(args.first == "git")
    #expect(args.contains("for-each-ref"))
    #expect(args.contains("refs/heads"))
    #expect(args.contains("--format=%(refname:short)\t%(upstream:short)"))
  }

  @Test func branchRefsDropsOriginHead() async throws {
    let output = """
      head\torigin/HEAD
      main\torigin/main
      """
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: output, stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")

    let refs = try await client.branchRefs(for: repoRoot)

    #expect(refs == ["head", "main", "origin/main"])
  }

  @Test func defaultRemoteBranchRefStripsPrefix() async throws {
    let shell = ShellClient(
      run: { _, _, _ in
        ShellOutput(stdout: "refs/remotes/origin/develop\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let ref = try await client.defaultRemoteBranchRef(for: URL(fileURLWithPath: "/tmp/repo"))

    #expect(ref == "origin/develop")
  }

  @Test func defaultRemoteBranchRefReturnsNilOnError() async throws {
    let shell = ShellClient(
      run: { _, _, _ in
        throw ShellClientError(command: "git", stdout: "", stderr: "boom", exitCode: 1)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let ref = try await client.defaultRemoteBranchRef(for: URL(fileURLWithPath: "/tmp/repo"))

    #expect(ref == nil)
  }

  @Test func defaultRemoteBranchRefFallsBackToOriginMain() async throws {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("symbolic-ref") {
          throw ShellClientError(command: "git", stdout: "", stderr: "missing", exitCode: 1)
        }
        if arguments.contains("rev-parse") {
          return ShellOutput(stdout: "hash", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let ref = try await client.defaultRemoteBranchRef(for: URL(fileURLWithPath: "/tmp/repo"))

    #expect(ref == "origin/main")
  }

  @Test func automaticWorktreeBaseRefUsesResolvedDefault() async throws {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("symbolic-ref") {
          return ShellOutput(stdout: "refs/remotes/origin/develop\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("rev-parse") {
          return ShellOutput(stdout: "hash", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let ref = await client.automaticWorktreeBaseRef(for: URL(fileURLWithPath: "/tmp/repo"))

    #expect(ref == "origin/develop")
  }

  @Test func automaticWorktreeBaseRefReturnsNilWhenUnavailable() async throws {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("symbolic-ref") || arguments.contains("rev-parse") {
          throw ShellClientError(command: "git", stdout: "", stderr: "missing", exitCode: 1)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let ref = await client.automaticWorktreeBaseRef(for: URL(fileURLWithPath: "/tmp/repo"))

    #expect(ref == nil)
  }
}
