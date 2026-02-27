import Foundation
import Testing

@testable import supacode

nonisolated final class GitShellInvocationRecorder: @unchecked Sendable {
  struct Snapshot {
    let executableURL: URL?
    let arguments: [String]
    let currentDirectoryURL: URL?
  }

  private let lock = NSLock()
  private var executableURLValue: URL?
  private var argumentsValue: [String] = []
  private var currentDirectoryURLValue: URL?

  func record(executableURL: URL, arguments: [String], currentDirectoryURL: URL?) {
    lock.lock()
    executableURLValue = executableURL
    argumentsValue = arguments
    currentDirectoryURLValue = currentDirectoryURL
    lock.unlock()
  }

  func snapshot() -> Snapshot {
    lock.lock()
    let value = Snapshot(
      executableURL: executableURLValue,
      arguments: argumentsValue,
      currentDirectoryURL: currentDirectoryURLValue
    )
    lock.unlock()
    return value
  }
}

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
}
