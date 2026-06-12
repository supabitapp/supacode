import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Asserts that a `GitClient` built on `ShellClient.ssh(host:)` rewrites a
/// worktree-create shell-out into the expected `ssh <host> <remoteCommand>`
/// wire invocation. The recorder stands in for the local `ssh` process so the
/// concatenation is checked without a real connection.
struct GitClientRemoteSSHTests {
  @Test func createWorktreeStreamOverSSHWrapsTheWtInvocation() async throws {
    let recorder = GitShellInvocationRecorder()
    let base = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { executableURL, arguments, currentDirectoryURL in
        recorder.record(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        return AsyncThrowingStream { continuation in
          continuation.yield(.line(ShellStreamLine(source: .stdout, text: "/tmp/repo/swift-otter")))
          continuation.yield(.finished(ShellOutput(stdout: "/tmp/repo/swift-otter", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      },
      runLoginStreamImpl: { _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    )
    let client = GitClient(shell: .ssh(host: RemoteHost(alias: "devbox"), base: base))

    for try await _ in client.createWorktreeStream(
      named: "swift-otter",
      in: URL(fileURLWithPath: "/tmp/repo"),
      baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      copyFiles: (ignored: false, untracked: false),
      baseRef: "origin/main"
    ) {}

    let snapshot = recorder.snapshot()
    // The transport spawns `ssh`, not the local tool, and drops the cwd (the
    // working directory becomes a remote `cd` inside the remote command).
    #expect(snapshot.executableURL == URL(fileURLWithPath: "/usr/bin/ssh"))
    #expect(snapshot.currentDirectoryURL == nil)

    // Fixed multiplexing options + destination precede the single remote-command arg.
    #expect(
      Array(snapshot.arguments.prefix(7)) == [
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=~/.ssh/supacode-%C",
        "-o", "ControlPersist=10m",
        "devbox",
      ]
    )
    #expect(snapshot.arguments.count == 8)

    // The single remote arg is login-shell wrapped (so Homebrew's PATH is on
    // the remote); the payload carries `cd -- <repoRoot> && exec … <wt> …`.
    // The wrapping re-quotes the inner single-quotes, so assert on bare tokens.
    let wrapped = snapshot.arguments[7]
    #expect(wrapped.hasPrefix("exec \"$SHELL\" -l -c "))
    #expect(wrapped.contains("cd -- "))
    #expect(wrapped.contains("/tmp/repo"))
    #expect(wrapped.contains("LANG=C"))
    #expect(wrapped.contains("--base-dir"))
    #expect(wrapped.contains("/tmp/repo/.worktrees"))
    #expect(wrapped.contains("sw"))
    #expect(wrapped.contains("--from"))
    #expect(wrapped.contains("origin/main"))
    #expect(wrapped.contains("swift-otter"))
  }

  @Test func createGitWorktreeOverSSHRunsWorktreeAdd() async throws {
    let recorder = GitShellInvocationRecorder()
    let base = ShellClient(
      run: { exe, args, cwd in
        recorder.record(executableURL: exe, arguments: args, currentDirectoryURL: cwd)
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: .ssh(host: RemoteHost(alias: "devbox"), base: base))

    try await client.createGitWorktree(
      in: URL(fileURLWithPath: "/repo"),
      name: "swift-otter",
      baseRef: "HEAD",
      worktreePath: URL(fileURLWithPath: "/swift-otter")
    )

    let snapshot = recorder.snapshot()
    #expect(snapshot.executableURL == URL(fileURLWithPath: "/usr/bin/ssh"))
    let wrapped = snapshot.arguments.last ?? ""
    #expect(wrapped.hasPrefix("exec \"$SHELL\" -l -c "))
    #expect(wrapped.contains("git"))
    #expect(wrapped.contains("worktree"))
    #expect(wrapped.contains("add"))
    #expect(wrapped.contains("-b"))
    #expect(wrapped.contains("swift-otter"))
    #expect(wrapped.contains("/swift-otter"))
    #expect(wrapped.contains("HEAD"))
  }

  @Test func removeWorktreeOverSSHRunsForcedWorktreeRemoveOnHost() async throws {
    let recorder = GitShellInvocationRecorder()
    let base = ShellClient(
      run: { exe, args, cwd in
        recorder.record(executableURL: exe, arguments: args, currentDirectoryURL: cwd)
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let host = RemoteHost(alias: "devbox")
    let client = GitClient(shell: .ssh(host: host, base: base))
    let worktree = Worktree(
      id: "devbox:/repo/wt",
      name: "wt",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/repo/wt"),
      repositoryRootURL: URL(fileURLWithPath: "/repo"),
      host: host
    )

    _ = try await client.removeWorktree(worktree, deleteBranch: false)

    // The removal runs `git worktree remove --force --force <path>` on the host,
    // not against the local checkout.
    let snapshot = recorder.snapshot()
    #expect(snapshot.executableURL == URL(fileURLWithPath: "/usr/bin/ssh"))
    let wrapped = snapshot.arguments.last ?? ""
    #expect(wrapped.contains("worktree"))
    #expect(wrapped.contains("remove"))
    #expect(wrapped.contains("--force"))
    #expect(wrapped.contains("/repo/wt"))
  }

  @Test func removeWorktreeOverSSHThrowsWhenHostRemoveFails() async throws {
    // The host remove is the only deletion for a remote worktree (no local
    // trash fallback), so a failure must surface instead of reporting success
    // and orphaning the worktree on the host.
    let host = RemoteHost(alias: "devbox")
    let base = ShellClient(
      run: { _, _, _ in
        throw ShellClientError(
          command: "ssh",
          stdout: "",
          stderr: "ssh: connect to host devbox port 22: Connection refused",
          exitCode: 255
        )
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: .ssh(host: host, base: base))
    let worktree = Worktree(
      id: "devbox:/repo/wt",
      name: "wt",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/repo/wt"),
      repositoryRootURL: URL(fileURLWithPath: "/repo"),
      host: host
    )

    await #expect(throws: (any Error).self) {
      _ = try await client.removeWorktree(worktree, deleteBranch: false)
    }
  }

  @Test func removeWorktreeOverSSHTreatsAlreadyGoneAsSuccess() async throws {
    // An entry already removed on the host is idempotent success, not a failure.
    let host = RemoteHost(alias: "devbox")
    let base = ShellClient(
      run: { _, _, _ in
        throw ShellClientError(
          command: "ssh",
          stdout: "",
          stderr: "fatal: '/repo/wt' is not a working tree",
          exitCode: 128
        )
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: .ssh(host: host, base: base))
    let worktree = Worktree(
      id: "devbox:/repo/wt",
      name: "wt",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/repo/wt"),
      repositoryRootURL: URL(fileURLWithPath: "/repo"),
      host: host
    )

    let removed = try await client.removeWorktree(worktree, deleteBranch: false)
    #expect(removed == URL(fileURLWithPath: "/repo/wt"))
  }

  @Test func removeWorktreeLeavesLocalFilesystemUntouchedForRemote() async throws {
    // The core invariant the branded location model exists to guarantee: a
    // remote worktree removal never touches a local directory that happens to
    // sit at the same absolute path.
    let fileManager = FileManager.default
    let localDirectory =
      fileManager.temporaryDirectory
      .appending(path: "supacode-remote-remove-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: localDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: localDirectory) }

    let host = RemoteHost(alias: "devbox")
    let base = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: .ssh(host: host, base: base))
    let worktree = Worktree(
      id: WorktreeID("devbox:\(localDirectory.path(percentEncoded: false))"),
      name: "wt",
      detail: "",
      workingDirectory: localDirectory,
      repositoryRootURL: URL(fileURLWithPath: "/repo"),
      host: host
    )

    _ = try await client.removeWorktree(worktree, deleteBranch: false)

    // Relocate-to-trash *moves* the directory, so it still existing in place is
    // proof the local filesystem path was never touched.
    #expect(fileManager.fileExists(atPath: localDirectory.path(percentEncoded: false)))
  }

  @Test func parseWorktreePorcelainParsesBranchDetachedAndSkipsBare() {
    let output = """
      bare

      worktree /repo
      HEAD aaa
      branch refs/heads/main

      worktree /repo/wt-feature
      HEAD bbb
      branch refs/heads/feature

      worktree /repo/wt-detached
      HEAD ccc
      detached
      """
    let worktrees = GitClient.parseWorktreePorcelain(output, repositoryRootURL: URL(fileURLWithPath: "/repo"))
    // The leading `bare` block is skipped.
    #expect(worktrees.count == 3)
    #expect(worktrees[0].name == "main")
    #expect(worktrees[0].isAttached)
    #expect(worktrees[1].name == "feature")
    #expect(worktrees[1].id == "/repo/wt-feature")
    // Detached worktree: not attached, name falls back to the dir leaf.
    #expect(worktrees[2].isAttached == false)
    #expect(worktrees[2].name == "wt-detached")
    // Remote paths aren't stat'd locally.
    #expect(worktrees.allSatisfy { !$0.isMissing })
  }

  @Test func gitWorktreesOverSSHRunsPorcelainListAndParses() async throws {
    let recorder = GitShellInvocationRecorder()
    let base = ShellClient(
      run: { exe, args, cwd in
        recorder.record(executableURL: exe, arguments: args, currentDirectoryURL: cwd)
        return ShellOutput(stdout: "worktree /repo\nHEAD abc\nbranch refs/heads/main\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: .ssh(host: RemoteHost(alias: "devbox"), base: base))

    let worktrees = try await client.gitWorktrees(for: URL(fileURLWithPath: "/repo"))
    #expect(worktrees.count == 1)
    #expect(worktrees[0].name == "main")

    // The wire command is `ssh devbox 'exec "$SHELL" -l -c …git worktree list --porcelain…'`.
    let snapshot = recorder.snapshot()
    #expect(snapshot.executableURL == URL(fileURLWithPath: "/usr/bin/ssh"))
    let wrapped = snapshot.arguments.last ?? ""
    #expect(wrapped.hasPrefix("exec \"$SHELL\" -l -c "))
    #expect(wrapped.contains("git"))
    #expect(wrapped.contains("worktree"))
    #expect(wrapped.contains("list"))
    #expect(wrapped.contains("--porcelain"))
  }
}
