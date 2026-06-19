import Darwin
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct WorktreeEnvironmentTests {
  @Test func scriptEnvironmentContainsExpectedKeys() {
    let worktree = Worktree(
      id: "/tmp/repo/wt-1",
      name: "feature-branch",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
    let env = worktree.scriptEnvironment
    #expect(env["SUPACODE_WORKTREE_PATH"] == "/tmp/repo/wt-1")
    #expect(env["SUPACODE_ROOT_PATH"] == "/tmp/repo")
    #expect(env.count == 2)
  }

  @Test func blockingScriptLaunchWritesScriptAndMetadataFiles() throws {
    let launch = try #require(
      try BlockingScriptRunner.makeLaunch(
        script: """
          docker compose down
          codex exec "test"
          """,
        shellPath: "/opt/homebrew/bin/fish"
      )
    )
    defer {
      try? FileManager.default.removeItem(at: launch.directoryURL)
    }

    let scriptContents = try String(contentsOf: launch.scriptURL, encoding: .utf8)
    let runnerScript = try String(contentsOf: launch.runnerURL, encoding: .utf8)
    let shellPathContents = try String(contentsOf: launch.shellPathURL, encoding: .utf8)

    #expect(
      launch.directoryURL.deletingLastPathComponent().path(percentEncoded: false)
        == FileManager.default.temporaryDirectory.path(percentEncoded: false)
    )
    #expect(
      launch.commandInput == BlockingScriptRunner.shellSingleQuoted(launch.runnerURL.path(percentEncoded: false)) + "\n"
    )
    #expect(scriptContents == "docker compose down\ncodex exec \"test\"\n")
    #expect(shellPathContents == "/opt/homebrew/bin/fish\n")
    let quotedShellPath = BlockingScriptRunner.shellSingleQuoted(
      launch.shellPathURL.path(percentEncoded: false))
    let quotedScriptPath = BlockingScriptRunner.shellSingleQuoted(
      launch.scriptURL.path(percentEncoded: false))
    #expect(runnerScript.contains("SUPACODE_SHELL_PATH_FILE=\(quotedShellPath)") == true)
    #expect(runnerScript.contains("\"$SUPACODE_SHELL_PATH\" -l \(quotedScriptPath)") == true)
    // The runner exec-tails after emitting OSC 133;D so the outer shell
    // stays blocked and no new prompt prints in the readonly tab. Both
    // 133;C and 133;D matter: blocking-script surfaces launch with
    // `disableShellIntegration` so Ghostty injects no integration / prompt
    // markers into the host shell; the runner must self-emit so the tab-bar
    // progress / `onCommandFinished` path still fires.
    #expect(runnerScript.contains("exec tail -f /dev/null") == true)
    #expect(runnerScript.contains("133;C") == true)
    #expect(runnerScript.contains("133;D") == true)
    #expect(runnerScript.contains("docker compose down") == false)
    #expect(runnerScript.contains("codex exec \"test\"") == false)
  }

  @Test func blockingScriptLaunchSetsOwnerOnlyPermissionsOnAllArtifacts() throws {
    let launch = try #require(
      try BlockingScriptRunner.makeLaunch(script: "echo ok", shellPath: "/bin/zsh")
    )
    defer { try? FileManager.default.removeItem(at: launch.directoryURL) }

    let fileManager = FileManager.default
    func mode(_ url: URL) throws -> Int {
      let attrs = try fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))
      return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    // Script + shell-path hold user secrets: 0o600. Directory + runner: 0o700.
    #expect(try mode(launch.directoryURL) == 0o700)
    #expect(try mode(launch.scriptURL) == 0o600)
    #expect(try mode(launch.shellPathURL) == 0o600)
    #expect(try mode(launch.runnerURL) == 0o700)
  }

  @Test func blockingScriptLaunchReturnsNilForWhitespaceOnlyScripts() throws {
    #expect(
      try BlockingScriptRunner.makeLaunch(
        script: """

          """,
        shellPath: "/bin/zsh"
      ) == nil
    )
  }

  @Test func remoteRunnerScriptFramesCdsAndRunsUserScriptAsChild() {
    let runner = BlockingScriptRunner.remoteRunnerScript(remoteWorktreePath: "/home/me/wt")
    // Same OSC 133 framing + read-only tail as the local runner, but on the host.
    #expect(runner.contains("133;C"))
    #expect(runner.contains("133;D"))
    #expect(runner.contains("exec tail -f /dev/null"))
    // cd into the remote worktree, then run the user script (`$1`) as a login-shell child.
    #expect(runner.contains("cd -- '/home/me/wt'"))
    #expect(runner.contains("\"$SHELL\" -l -c \"$1\""))
    // Beta banner present (remote surfaces are in beta).
    #expect(runner.contains("beta"))
  }

  @Test func remoteRunnerScriptSkipsCdForRootOrEmptyPath() {
    #expect(!BlockingScriptRunner.remoteRunnerScript(remoteWorktreePath: "/").contains("cd -- "))
    #expect(!BlockingScriptRunner.remoteRunnerScript(remoteWorktreePath: "  ").contains("cd -- "))
  }

  @Test func remoteCommandWrapsRunnerInSSHWithUserScriptPositional() {
    let host = RemoteHost(alias: "devbox", username: "alice", port: 2222)
    let line = BlockingScriptRunner.remoteCommand(host: host, script: "echo hi", remoteWorktreePath: "/home/me/wt")
    #expect(line?.hasPrefix("/usr/bin/ssh ") == true)
    #expect(line?.contains("-p 2222 alice@devbox ") == true)
    #expect(line?.contains("133;C") == true)
    // The user script rides as a positional argument to the remote `-c` script.
    #expect(line?.contains("'echo hi'") == true)
    // No local blocking-script temp dir is referenced for the remote path.
    #expect(line?.contains("supacode-blocking-script-") == false)
  }

  @Test func remoteCommandReturnsNilForEmptyScript() {
    let host = RemoteHost(alias: "devbox")
    #expect(BlockingScriptRunner.remoteCommand(host: host, script: "   ", remoteWorktreePath: "/p") == nil)
  }

  @Test func blockingScriptLaunchPropagatesNonZeroExitCodeInZsh() throws {
    let launch = try #require(
      try BlockingScriptRunner.makeLaunch(
        script: "exit 1",
        shellPath: "/bin/zsh"
      )
    )
    let tempHome = URL(
      fileURLWithPath: "/tmp/supacode-zsh-home-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: launch.directoryURL)
      try? FileManager.default.removeItem(at: tempHome)
    }

    let process = Process()
    process.executableURL = launch.runnerURL
    process.environment = ["HOME": tempHome.path(percentEncoded: false)]
    // The runner exec-tails when `[ -t 0 ]`, hanging forever; force a non-TTY
    // stdin so the `else exit "$SUPACODE_EXIT"` branch wins under xctest.
    process.standardInput = Pipe()

    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 1)
  }

  @Test func blockingScriptCommandInputHandlesQuotedTempPathsInZsh() throws {
    let fileManager = FileManager.default
    let baseDirectoryURL = fileManager.temporaryDirectory.appending(
      path: "supacode temporary path's with spaces \(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    let launch = try #require(
      try BlockingScriptRunner.makeLaunch(
        script: "exit 1",
        shellPath: "/bin/zsh",
        baseDirectoryURL: baseDirectoryURL
      )
    )
    let tempHome = fileManager.temporaryDirectory.appending(
      path: "supacode-zsh-home-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: tempHome, withIntermediateDirectories: true)
    defer {
      try? fileManager.removeItem(at: launch.directoryURL)
      try? fileManager.removeItem(at: baseDirectoryURL)
      try? fileManager.removeItem(at: tempHome)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", launch.commandInput]
    process.environment = ["HOME": tempHome.path(percentEncoded: false)]
    // Same non-TTY override as the sibling test: the runner's `[ -t 0 ]`
    // gate would otherwise `exec tail -f /dev/null` and hang the test.
    process.standardInput = Pipe()

    try process.run()
    process.waitUntilExit()

    #expect(launch.commandInput.starts(with: "'") == true)
    #expect(process.terminationStatus == 1)
  }

  @Test func blockingScriptRunnerEmits133CDPairWhenShellPathDisappears() throws {
    let launch = try #require(
      try BlockingScriptRunner.makeLaunch(
        script: "true",
        shellPath: "/bin/zsh"
      )
    )
    defer {
      try? FileManager.default.removeItem(at: launch.directoryURL)
    }
    // Simulate a TOCTOU between `[ -r ]` and `read -r`: shell-path file
    // vanishes after `makeLaunch` wrote it. The trap must still pair 133;D
    // with the hoisted 133;C so `command_finished` always fires.
    try FileManager.default.removeItem(at: launch.shellPathURL)

    let stdoutPipe = Pipe()
    let process = Process()
    process.executableURL = launch.runnerURL
    process.standardInput = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()

    let stdout =
      String(
        data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    #expect(process.terminationStatus == 127)
    #expect(stdout.contains("\u{1B}]133;C\u{07}"))
    #expect(stdout.contains("\u{1B}]133;D;127\u{07}"))
  }

  @Test func blockingScriptRunnerEmitsCommandFinishedUnderRealPTYBeforeExecTail() throws {
    let launch = try #require(
      try BlockingScriptRunner.makeLaunch(script: "true", shellPath: "/bin/zsh")
    )
    let tempHome = FileManager.default.temporaryDirectory.appending(
      path: "supacode-pty-home-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: launch.directoryURL)
      try? FileManager.default.removeItem(at: tempHome)
    }

    // Allocate a real PTY so `[ -t 0 ]` is true and the runner takes the
    // `exec tail -f /dev/null` branch (the actual shipping path). Stdin only
    // needs to be a TTY for the gate; stdout still goes through a pipe.
    var controllerFD: Int32 = -1
    var subordinateFD: Int32 = -1
    #expect(openpty(&controllerFD, &subordinateFD, nil, nil, nil) == 0)
    defer {
      close(controllerFD)
      close(subordinateFD)
    }

    let stdoutPipe = Pipe()
    let process = Process()
    process.executableURL = launch.runnerURL
    process.environment = ["HOME": tempHome.path(percentEncoded: false)]
    process.standardInput = FileHandle(fileDescriptor: subordinateFD, closeOnDealloc: false)
    process.standardOutput = stdoutPipe
    process.standardError = Pipe()
    try process.run()

    // Let the runner emit 133;C, execute `true`, emit 133;D, then block on
    // `exec tail`. Half a second is comfortable on local + CI; the alternative
    // (poll readabilityHandler) needs lock-guarded shared state for a fixed
    // payload we're only inspecting after termination.
    Thread.sleep(forTimeInterval: 0.5)
    process.terminate()
    process.waitUntilExit()

    let observed =
      String(
        data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    #expect(observed.contains("\u{1B}]133;C\u{07}"), "133;C missing from PTY stdout")
    #expect(observed.contains("\u{1B}]133;D;0\u{07}"), "133;D missing from PTY stdout")
    // 133;C must precede 133;D so Ghostty's command timer pairs correctly.
    if let cRange = observed.range(of: "\u{1B}]133;C\u{07}"),
      let dRange = observed.range(of: "\u{1B}]133;D;0\u{07}")
    {
      #expect(cRange.lowerBound < dRange.lowerBound)
    }
  }
}
