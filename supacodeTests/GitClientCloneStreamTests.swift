import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct GitClientCloneArgumentsTests {
  @Test func includesProgressAndPositionalUrlAndDestination() {
    let args = GitClient.cloneArguments(
      repositoryURL: "https://github.com/org/repo.git",
      destination: URL(fileURLWithPath: "/tmp/dest/repo"),
      branch: nil,
      depth: nil
    )
    #expect(args == ["clone", "--progress", "--", "https://github.com/org/repo.git", "/tmp/dest/repo"])
  }

  @Test func includesBranchAndDepthWhenProvided() {
    let args = GitClient.cloneArguments(
      repositoryURL: "git@github.com:org/repo.git",
      destination: URL(fileURLWithPath: "/tmp/dest/repo"),
      branch: "main",
      depth: 1
    )
    #expect(
      args == [
        "clone", "--progress", "--branch", "main", "--depth", "1",
        "--", "git@github.com:org/repo.git", "/tmp/dest/repo",
      ]
    )
  }

  @Test func dropsEmptyBranchAndNonPositiveDepth() {
    let args = GitClient.cloneArguments(
      repositoryURL: "https://example.com/x.git",
      destination: URL(fileURLWithPath: "/d"),
      branch: "",
      depth: 0
    )
    #expect(!args.contains("--branch"))
    #expect(!args.contains("--depth"))
  }
}

struct GitCloneHumanishNameTests {
  @Test func derivesLeafFromHttpsScpAndTrailingForms() {
    #expect(GitClient.humanishName(forCloneURL: "https://github.com/org/repo.git") == "repo")
    #expect(GitClient.humanishName(forCloneURL: "https://github.com/org/repo") == "repo")
    #expect(GitClient.humanishName(forCloneURL: "git@github.com:org/repo.git") == "repo")
    #expect(GitClient.humanishName(forCloneURL: "git@github.com:repo.git") == "repo")
    #expect(GitClient.humanishName(forCloneURL: "https://github.com/org/repo.git/") == "repo")
    #expect(GitClient.humanishName(forCloneURL: "ssh://git@host/org/repo.git") == "repo")
    #expect(GitClient.humanishName(forCloneURL: "https://github.com/org/repo.git?ref=main") == "repo")
    #expect(GitClient.humanishName(forCloneURL: "  https://github.com/org/repo.git  ") == "repo")
  }

  @Test func returnsEmptyWhenNoLeafDerivable() {
    #expect(GitClient.humanishName(forCloneURL: "") == "")
    #expect(GitClient.humanishName(forCloneURL: "/") == "")
    #expect(GitClient.humanishName(forCloneURL: "https://") == "")
  }
}

struct GitCloneCredentialRedactionTests {
  @Test func extractsUserinfoForUserPasswordAndTokenForms() {
    #expect(GitClient.cloneCredentials(of: "https://user:token@github.com/org/repo.git") == "user:token")
    #expect(GitClient.cloneCredentials(of: "https://ghp_secrettoken@github.com/org/repo.git") == "ghp_secrettoken")
  }

  @Test func extractsNilForCredentiallessUrls() {
    #expect(GitClient.cloneCredentials(of: "https://github.com/org/repo.git") == nil)
    #expect(GitClient.cloneCredentials(of: "git@github.com:org/repo.git") == nil)
  }

  @Test func treatsSshLoginNameAsNonSecret() {
    // An ssh url's user (`git@host`) is a login name, not a credential; redacting
    // it would mangle `git` / the host in surfaced output.
    #expect(GitClient.cloneCredentials(of: "ssh://git@github.com/org/repo.git") == nil)
    #expect(GitClient.cloneCredentials(of: "ssh://git@host:2222/org/repo.git") == nil)
    // An explicit password is a secret even over ssh.
    #expect(GitClient.cloneCredentials(of: "ssh://user:secret@host/org/repo.git") == "user:secret")
    // http(s) bare user is a token; an http password is still a secret.
    #expect(GitClient.cloneCredentials(of: "http://user:pass@host/x.git") == "user:pass")
  }

  @Test func redactsCredentialInStreamedLinesAndWrappedErrorDespiteUrlNormalization() async {
    let token = "ghp_secrettoken"
    let credURL = "https://\(token)@github.com/org/repo.git"
    // git normalizes the echoed url (here a trailing slash), so an exact-url
    // match would miss it; the substring match must still redact the token.
    let echoedURL = "https://\(token)@github.com/org/repo.git/"
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { _, _, _ in AsyncThrowingStream { $0.finish() } },
      runLoginStreamImpl: { _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(
            .line(ShellStreamLine(source: .stderr, text: "fatal: Authentication failed for '\(echoedURL)'")))
          continuation.finish(
            throwing: ShellClientError(
              command: "git clone \(credURL)",
              stdout: "",
              stderr: "fatal: Authentication failed for '\(echoedURL)'",
              exitCode: 128
            )
          )
        }
      }
    )
    var streamedText = ""
    var thrownMessage = ""
    do {
      for try await event in GitClient(shell: shell).cloneStream(
        repositoryURL: credURL,
        into: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "redact-\(UUID().uuidString)/repo"),
        branch: nil,
        depth: nil
      ) {
        if case .outputLine(let line) = event { streamedText += line.text }
      }
    } catch {
      thrownMessage = error.localizedDescription
    }
    #expect(!streamedText.contains(token))
    #expect(!thrownMessage.contains(token))
    #expect(thrownMessage.contains("github.com"))
  }
}

struct GitClientDirectoryURLTests {
  /// Compares paths ignoring a trailing slash, which is a URL representation
  /// artifact (a directory URL renders one) irrelevant to the resolved folder.
  private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
    func trimmed(_ url: URL) -> String {
      let path = url.path(percentEncoded: false)
      return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
    return trimmed(lhs) == trimmed(rhs)
  }

  @Test func existingDirectoryWithoutTrailingSlashResolvesToItself() throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "wt-root-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    // Mirrors a cloned destination: `appending` infers a non-directory from the
    // path string, so `hasDirectoryPath` is false even after the dir exists.
    let target = parent.appending(path: "repo")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    #expect(!target.hasDirectoryPath)
    #expect(samePath(GitClient.directoryURL(for: target), target))
  }

  @Test func filePathResolvesToParentDirectory() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "wt-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(path: "HEAD")
    try Data("ref".utf8).write(to: file)
    #expect(samePath(GitClient.directoryURL(for: file), dir))
  }
}

struct GitClientCloneStreamCleanupTests {
  private static func failingShell(onInvoke: (@Sendable () -> Void)? = nil) -> ShellClient {
    ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { _, _, _ in AsyncThrowingStream { $0.finish() } },
      runLoginStreamImpl: { _, _, _, _ in
        onInvoke?()
        return AsyncThrowingStream {
          $0.finish(throwing: ShellClientError(command: "git clone", stdout: "", stderr: "fatal", exitCode: 128))
        }
      }
    )
  }

  @Test func failedClonePreservesPreExistingDestination() async {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "clone-preexist-\(UUID().uuidString)")
    let destination = base.appending(path: "repo")
    try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let sentinel = destination.appending(path: "keep.txt")
    try? Data("x".utf8).write(to: sentinel)
    defer { try? FileManager.default.removeItem(at: base) }

    await #expect(throws: (any Error).self) {
      for try await _ in GitClient(shell: Self.failingShell())
        .cloneStream(repositoryURL: "https://example.com/x.git", into: destination, branch: nil, depth: nil)
      {}
    }
    #expect(FileManager.default.fileExists(atPath: sentinel.path(percentEncoded: false)))
  }

  @Test func failedClonePreservesPreExistingFileAtDestination() async {
    // A regular file at the destination path is the user's; git never created it,
    // so a failed clone must not delete it.
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "clone-file-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let destination = base.appending(path: "repo")
    try? Data("user data".utf8).write(to: destination)
    defer { try? FileManager.default.removeItem(at: base) }

    await #expect(throws: (any Error).self) {
      for try await _ in GitClient(shell: Self.failingShell())
        .cloneStream(repositoryURL: "https://example.com/x.git", into: destination, branch: nil, depth: nil)
      {}
    }
    #expect(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
  }

  @Test func failedCloneRemovesCreatedDestination() async {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "clone-created-\(UUID().uuidString)")
    let destination = base.appending(path: "repo")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    // The fake git creates the destination then fails, mirroring a real partial clone.
    let shell = Self.failingShell {
      try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    await #expect(throws: (any Error).self) {
      for try await _ in GitClient(shell: shell)
        .cloneStream(repositoryURL: "https://example.com/x.git", into: destination, branch: nil, depth: nil)
      {}
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
  }

  @Test func failedCloneRemovesPreExistingEmptyDestination() async {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "clone-empty-\(UUID().uuidString)")
    let destination = base.appending(path: "repo")
    // git allows cloning into an existing empty dir, so a failed clone into it
    // must still be cleaned up or a retry hits "already exists".
    try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let shell = Self.failingShell {
      try? Data("partial".utf8).write(to: destination.appending(path: "HEAD"))
    }
    await #expect(throws: (any Error).self) {
      for try await _ in GitClient(shell: shell)
        .cloneStream(repositoryURL: "https://example.com/x.git", into: destination, branch: nil, depth: nil)
      {}
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
  }

  @Test func emptyOutputThrowsCommandFailed() async {
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { _, _, _ in AsyncThrowingStream { $0.finish() } },
      runLoginStreamImpl: { _, _, _, _ in AsyncThrowingStream { $0.finish() } }
    )
    let destination = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "clone-empty-\(UUID().uuidString)/repo")
    await #expect(throws: GitClientError.self) {
      for try await _ in GitClient(shell: shell)
        .cloneStream(repositoryURL: "https://example.com/x.git", into: destination, branch: nil, depth: nil)
      {}
    }
  }
}

struct GitClientCloneStreamInvocationTests {
  @Test func invokesGitCloneWithFailFastEnvAndYieldsDestination() async throws {
    let recorder = GitShellInvocationRecorder()
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { _, _, _ in
        AsyncThrowingStream { $0.finish() }
      },
      runLoginStreamImpl: { executableURL, arguments, currentDirectoryURL, _ in
        recorder.record(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL
        )
        return AsyncThrowingStream { continuation in
          continuation.yield(.line(ShellStreamLine(source: .stderr, text: "Receiving objects: 100%")))
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    )
    let destination = URL(fileURLWithPath: "/tmp/dest/repo")
    var finishedDirectory: URL?
    for try await event in GitClient(shell: shell).cloneStream(
      repositoryURL: "https://github.com/org/repo.git",
      into: destination,
      branch: "main",
      depth: 1
    ) {
      if case .finished(let directory) = event {
        finishedDirectory = directory
      }
    }

    let snapshot = recorder.snapshot()
    // The clone runs through the PATH-augmenting `/bin/sh` wrapper so `git` can
    // find `git-lfs` during the checkout smudge filter (#663).
    #expect(snapshot.executableURL?.path == "/bin/sh")
    #expect(snapshot.arguments.contains { $0.contains("export PATH=") })
    #expect(snapshot.arguments.contains("GIT_TERMINAL_PROMPT=0"))
    let gitIndex = try #require(snapshot.arguments.firstIndex(of: "git"))
    #expect(
      Array(snapshot.arguments[gitIndex...]) == [
        "git", "clone", "--progress", "--branch", "main", "--depth", "1",
        "--", "https://github.com/org/repo.git", "/tmp/dest/repo",
      ]
    )
    #expect(finishedDirectory?.standardizedFileURL == destination.standardizedFileURL)
  }
}
