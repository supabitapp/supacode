import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct GitClientCreateWorktreeStreamTests {
  @Test func createWorktreeStreamAddsVerboseWhenCopyingFiles() async throws {
    let recorder = GitShellInvocationRecorder()
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      },
      runLoginStreamImpl: { executableURL, arguments, currentDirectoryURL, _ in
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
      }
    )
    let client = GitClient(shell: shell)
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")

    for try await _ in client.createWorktreeStream(
      named: "swift-otter",
      in: repoRoot,
      baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      copyFiles: (ignored: true, untracked: false),
      baseRef: "origin/main"
    ) {}

    let snapshot = recorder.snapshot()
    #expect(snapshot.currentDirectoryURL == repoRoot)
    #expect(snapshot.arguments.contains("sw"))
    if let baseDirFlagIndex = snapshot.arguments.firstIndex(of: "--base-dir") {
      #expect(snapshot.arguments.count > baseDirFlagIndex + 1)
      #expect(snapshot.arguments[baseDirFlagIndex + 1] == "/tmp/repo/.worktrees")
    } else {
      Issue.record("Expected --base-dir in createWorktreeStream arguments")
    }
    #expect(snapshot.arguments.contains("--copy-ignored"))
    #expect(snapshot.arguments.contains("--verbose"))
    #expect(snapshot.arguments.contains("--from"))
    #expect(snapshot.arguments.contains("origin/main"))
    #expect(snapshot.arguments.contains("swift-otter"))
  }

  @Test func createWorktreeStreamForwardsDirectoryOverrideAsPathFlag() async throws {
    let recorder = GitShellInvocationRecorder()
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      },
      runLoginStreamImpl: { executableURL, arguments, currentDirectoryURL, _ in
        recorder.record(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        return AsyncThrowingStream { continuation in
          continuation.yield(.line(ShellStreamLine(source: .stdout, text: "/tmp/elsewhere/feature_foo")))
          continuation.yield(
            .finished(ShellOutput(stdout: "/tmp/elsewhere/feature_foo", stderr: "", exitCode: 0))
          )
          continuation.finish()
        }
      }
    )
    let client = GitClient(shell: shell)
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")

    for try await _ in client.createWorktreeStream(
      named: "feature/foo",
      in: repoRoot,
      baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      copyFiles: (ignored: false, untracked: false),
      baseRef: "origin/main",
      directoryOverride: URL(fileURLWithPath: "/tmp/elsewhere/feature_foo")
    ) {}

    let snapshot = recorder.snapshot()
    if let pathFlagIndex = snapshot.arguments.firstIndex(of: "--path") {
      #expect(snapshot.arguments.count > pathFlagIndex + 1)
      #expect(snapshot.arguments[pathFlagIndex + 1] == "/tmp/elsewhere/feature_foo")
    } else {
      Issue.record("Expected --path in createWorktreeStream arguments")
    }
    // The branch stays the positional argument; only the directory is overridden.
    #expect(snapshot.arguments.contains("feature/foo"))
  }

  @Test func createWorktreeStreamForwardsOutputLines() async throws {
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      },
      runLoginStreamImpl: { _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.line(ShellStreamLine(source: .stderr, text: "[1/2] copy .env")))
          continuation.yield(.line(ShellStreamLine(source: .stdout, text: "preparing")))
          continuation.yield(.line(ShellStreamLine(source: .stdout, text: "/tmp/repo/swift-otter")))
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    )
    let client = GitClient(shell: shell)
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    var outputLines: [ShellStreamLine] = []
    var finishedWorktree: Worktree?
    for try await event in client.createWorktreeStream(
      named: "swift-otter",
      in: repoRoot,
      baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      copyFiles: (ignored: true, untracked: true),
      baseRef: ""
    ) {
      switch event {
      case .outputLine(let line):
        outputLines.append(line)
      case .finished(let worktree):
        finishedWorktree = worktree
      }
    }

    #expect(outputLines.count == 3)
    #expect(outputLines[0] == ShellStreamLine(source: .stderr, text: "[1/2] copy .env"))
    #expect(outputLines[1] == ShellStreamLine(source: .stdout, text: "preparing"))
    #expect(outputLines[2] == ShellStreamLine(source: .stdout, text: "/tmp/repo/swift-otter"))
    #expect(finishedWorktree?.id == "/tmp/repo/swift-otter")
  }

  @Test func createWorktreeStreamUsesLastNonEmptyStdoutLineAsPath() async throws {
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      },
      runLoginStreamImpl: { _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.line(ShellStreamLine(source: .stdout, text: "creating")))
          continuation.yield(.line(ShellStreamLine(source: .stdout, text: "")))
          continuation.yield(.line(ShellStreamLine(source: .stdout, text: "/tmp/repo/new-wt")))
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    )
    let client = GitClient(shell: shell)
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    var finishedWorktree: Worktree?
    for try await event in client.createWorktreeStream(
      named: "new-wt",
      in: repoRoot,
      baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      copyFiles: (ignored: false, untracked: false),
      baseRef: ""
    ) {
      if case .finished(let worktree) = event {
        finishedWorktree = worktree
      }
    }

    #expect(finishedWorktree?.id == "/tmp/repo/new-wt")
    #expect(finishedWorktree?.workingDirectory == URL(fileURLWithPath: "/tmp/repo/new-wt"))
  }

  @Test func createWorktreeStreamUsesFinishedOutputWhenNoLineEventsAreEmitted() async throws {
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in
        ShellOutput(
          stdout: "creating worktree\n/tmp/repo/new-wt\n",
          stderr: "",
          exitCode: 0
        )
      }
    )
    let client = GitClient(shell: shell)
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")
    var outputLines: [ShellStreamLine] = []
    var finishedWorktree: Worktree?
    for try await event in client.createWorktreeStream(
      named: "new-wt",
      in: repoRoot,
      baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      copyFiles: (ignored: false, untracked: false),
      baseRef: ""
    ) {
      switch event {
      case .outputLine(let line):
        outputLines.append(line)
      case .finished(let worktree):
        finishedWorktree = worktree
      }
    }

    #expect(outputLines.isEmpty)
    #expect(finishedWorktree?.id == "/tmp/repo/new-wt")
    #expect(finishedWorktree?.workingDirectory == URL(fileURLWithPath: "/tmp/repo/new-wt"))
  }

  @Test func createWorktreeStreamThrowsWhenNoPathLineIsEmitted() async throws {
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      },
      runLoginStreamImpl: { _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.line(ShellStreamLine(source: .stderr, text: "[1/10] copy .env")))
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    )
    let client = GitClient(shell: shell)
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")

    do {
      for try await _ in client.createWorktreeStream(
        named: "new-wt",
        in: repoRoot,
        baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
        copyFiles: (ignored: false, untracked: false),
        baseRef: ""
      ) {}
      Issue.record("Expected createWorktreeStream to throw when stdout path is missing")
    } catch let error as GitClientError {
      #expect(error.localizedDescription.contains("Empty output"))
    }
  }

  @Test func createWorktreeWrapsShellClientError() async throws {
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      },
      runLoginStreamImpl: { _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.finish(
            throwing: ShellClientError(
              command: "wt sw",
              stdout: "out",
              stderr: "err",
              exitCode: 1
            )
          )
        }
      }
    )
    let client = GitClient(shell: shell)
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")

    do {
      _ = try await client.createWorktree(
        named: "new-wt",
        in: repoRoot,
        baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
        copyFiles: (ignored: false, untracked: false),
        baseRef: ""
      )
      Issue.record("Expected createWorktree to throw")
    } catch let error as GitClientError {
      #expect(error.localizedDescription.contains("Git command failed"))
      #expect(error.localizedDescription.contains("stdout:\nout"))
      #expect(error.localizedDescription.contains("stderr:\nerr"))
    }
  }

  @Test func createWorktreeReturnsFinishedWorktreeFromStream() async throws {
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      },
      runLoginStreamImpl: { _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.line(ShellStreamLine(source: .stdout, text: "/tmp/repo/new-wt")))
          continuation.yield(.finished(ShellOutput(stdout: "/tmp/repo/new-wt", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    )
    let client = GitClient(shell: shell)
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")

    let worktree = try await client.createWorktree(
      named: "new-wt",
      in: repoRoot,
      baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      copyFiles: (ignored: false, untracked: false),
      baseRef: ""
    )

    #expect(worktree.id == "/tmp/repo/new-wt")
    #expect(worktree.name == "new-wt")
    #expect(worktree.repositoryRootURL == repoRoot)
  }

  @Test func createWorktreeUsesFinishedOutputWhenNoLineEventsAreEmitted() async throws {
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in
        ShellOutput(
          stdout: "preparing\n/tmp/repo/new-wt\n",
          stderr: "",
          exitCode: 0
        )
      }
    )
    let client = GitClient(shell: shell)
    let repoRoot = URL(fileURLWithPath: "/tmp/repo")

    let worktree = try await client.createWorktree(
      named: "new-wt",
      in: repoRoot,
      baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      copyFiles: (ignored: false, untracked: false),
      baseRef: ""
    )

    #expect(worktree.id == "/tmp/repo/new-wt")
    #expect(worktree.name == "new-wt")
    #expect(worktree.repositoryRootURL == repoRoot)
  }

  @Test func createWorktreeStreamRunsThroughPathAugmentingWrapper() async throws {
    let recorder = GitShellInvocationRecorder()
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      },
      runLoginStreamImpl: { executableURL, arguments, currentDirectoryURL, _ in
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
      }
    )
    let client = GitClient(shell: shell)

    for try await _ in client.createWorktreeStream(
      named: "swift-otter",
      in: URL(fileURLWithPath: "/tmp/repo"),
      baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      copyFiles: (ignored: false, untracked: false),
      baseRef: "origin/main"
    ) {}

    let snapshot = recorder.snapshot()
    // The worktree add runs through the PATH-augmenting `/bin/sh` wrapper so
    // `git` can find `git-lfs` during the checkout smudge filter (#663).
    #expect(snapshot.executableURL?.path == "/bin/sh")
    #expect(snapshot.arguments.contains { $0.contains("export PATH=") })
    // The wrapped command execs the original env + wt invocation as the trailing
    // args after the `sh` argv[0] filler.
    let shIndex = try #require(snapshot.arguments.firstIndex(of: "sh"))
    #expect(snapshot.arguments[shIndex + 1] == "/usr/bin/env")
    #expect(snapshot.arguments.contains("sw"))
    #expect(snapshot.arguments.contains("swift-otter"))
  }
}

struct GitClientPathAugmentationTests {
  @Test func filterHelperDirectoriesAreTheFixedToolLocations() {
    #expect(
      GitClient.gitFilterHelperDirectories() == ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
    )
  }

  @Test func pathAugmentedInvocationWrapsCommandInPathExportingShell() {
    let invocation = GitClient.pathAugmentedInvocation(
      command: ["/usr/bin/env", "LANG=C", "/path/wt", "sw"],
      directories: ["/opt/homebrew/bin", "/usr/local/bin"]
    )
    #expect(invocation.executable.path == "/bin/sh")
    #expect(
      invocation.arguments == [
        "-c",
        "export PATH=\"${PATH:+$PATH:}\"'/opt/homebrew/bin:/usr/local/bin'\"${HOME:+:$HOME/.local/bin}\"; exec \"$@\"",
        "sh",
        "/usr/bin/env", "LANG=C", "/path/wt", "sw",
      ]
    )
  }

  @Test func pathAugmentedInvocationAppendsDirectoriesWhenExecuted() throws {
    let invocation = GitClient.pathAugmentedInvocation(
      command: ["/bin/sh", "-c", "printf %s \"$PATH\""],
      directories: ["/opt/homebrew/bin"]
    )
    // An existing PATH keeps precedence; the fixed dir and the execution host's
    // own `~/.local/bin` are appended after it.
    #expect(
      try Self.capturedPath(running: invocation, path: "/usr/bin", home: "/tmp/home")
        == "/usr/bin:/opt/homebrew/bin:/tmp/home/.local/bin")
    // An empty PATH drops the leading colon that would otherwise put the cwd on
    // PATH; an unset HOME drops the per-user entry.
    #expect(try Self.capturedPath(running: invocation, path: "", home: nil) == "/opt/homebrew/bin")
  }

  /// Runs `invocation` with a controlled `PATH` and `HOME` and returns the
  /// `$PATH` its wrapped command observes, so the augmentation is verified as
  /// behavior on the execution host.
  private static func capturedPath(
    running invocation: (executable: URL, arguments: [String]),
    path: String,
    home: String?
  ) throws -> String {
    let process = Process()
    process.executableURL = invocation.executable
    process.arguments = invocation.arguments
    var environment = ["PATH": path]
    environment["HOME"] = home
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(bytes: data, encoding: .utf8) ?? ""
  }
}
