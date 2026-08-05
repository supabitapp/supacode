import Foundation
import Testing

/// Runs the remote-shell quoting regression tests against real login shells, so
/// a quoting change is validated by the parsers that actually see it rather
/// than by a golden string.
nonisolated enum LoginShellProbe {
  struct Result {
    var status: Int32
    var stdout: String
    var stderr: String

    /// The stderr lines that read as a parse failure. Asserting on these rather
    /// than on an empty stderr keeps a plugin's own warning from failing a
    /// quoting test, while still catching a token the shell could not parse.
    var shellDiagnostics: [String] {
      let signatures = [
        "unexpected", "syntax error", "unmatched", "not balanced", "missing end",
        "unterminated", "quote", "parse error", "bad substitution", "event not found",
      ]
      return
        stderr
        .split(separator: "\n")
        .map(String.init)
        .filter { line in
          let lowercased = line.lowercased()
          return signatures.contains { lowercased.contains($0) }
        }
    }
  }

  /// The shells whose parsers `SSHCommand.loginShellQuote` promises to satisfy.
  /// `sh` is the POSIX baseline; `fish` is the shell the contract exists for.
  static let quotingContractShells = ["sh", "bash", "zsh", "fish"]

  /// Resolves a shell by name, preferring `PATH` so a MacPorts / nix install
  /// counts. `make doctor` reports fish as a prerequisite, so a missing one is
  /// a hard failure rather than a silent skip.
  static func executable(_ name: String) throws -> URL {
    let candidates =
      (ProcessInfo.processInfo.environment["PATH"] ?? "")
      .split(separator: ":")
      .map { URL(fileURLWithPath: String($0)).appending(path: name) }
      + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/opt/local/bin"]
      .map { URL(fileURLWithPath: $0).appending(path: name) }
    return try #require(
      candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) },
      "\(name) is required for the remote-shell quoting regression tests (run `make doctor`)"
    )
  }

  /// A `-c` invocation of `shell` with an isolated config root and a fixed
  /// environment, so a developer's own rc files and `TERM` can't change which
  /// branch the command under test takes.
  static func run(
    _ shell: String,
    command: String,
    configRoot: URL,
    shellPathOverride: String? = nil,
    extraEnvironment: [String: String] = [:]
  ) async throws -> Result {
    let executableURL = try executable(shell)
    try FileManager.default.createDirectory(
      at: configRoot.appending(path: "fish"),
      withIntermediateDirectories: true
    )
    let process = Process()
    process.executableURL = executableURL
    process.arguments = (shell == "fish" ? ["--no-config"] : []) + ["-c", command]
    process.environment = [
      "HOME": configRoot.path,
      "XDG_CONFIG_HOME": configRoot.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin",
      "SHELL": shellPathOverride ?? executableURL.path,
      "TERM": "dumb",
    ].merging(extraEnvironment) { _, new in new }
    // Not a tty, so the runner scripts' `[ -t 0 ] && exec tail -f /dev/null`
    // can't wedge the suite, and EOF is immediate so a script that reads stdin
    // can't block the drain below forever.
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    // Drain concurrently: reading only after exit deadlocks a child that fills
    // the ~64KB pipe buffer. A failed spawn leaves the write ends open, so
    // close them or the reads never see EOF.
    let outputRead = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
    let errorRead = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
    do {
      try await process.runToExit()
    } catch {
      try? stdout.fileHandleForWriting.close()
      try? stderr.fileHandleForWriting.close()
      throw error
    }

    return Result(
      status: process.terminationStatus,
      stdout: try #require(String(bytes: await outputRead.value, encoding: .utf8)),
      stderr: try #require(String(bytes: await errorRead.value, encoding: .utf8))
    )
  }

  /// The path `pwd -P` reports. Foundation's `resolvingSymlinksInPath` keeps
  /// `/var`, where the filesystem resolves it to `/private/var`.
  static func physicalPath(of url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// A temporary directory removed when `body` returns, so a fixture named
  /// `worktree:it's\literal` never leaks into the temp tree.
  static func withTemporaryDirectory<T>(
    _ name: String,
    body: (URL) async throws -> T
  ) async throws -> T {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "supacode-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
  }
}
