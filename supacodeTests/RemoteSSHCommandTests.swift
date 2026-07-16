import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct WellKnownToolDirectoriesTests {
  @Test func absoluteListCoversMacAndLinuxToolPrefixes() {
    let dirs = WellKnownToolDirectories.absolute
    #expect(dirs.contains("/opt/homebrew/bin"))  // macOS Apple Silicon.
    #expect(dirs.contains("/usr/local/bin"))  // macOS Intel / common.
    #expect(dirs.contains("/opt/local/bin"))  // macOS MacPorts.
    #expect(dirs.contains("/home/linuxbrew/.linuxbrew/bin"))  // Linux shared (#671).
  }

  @Test func pathExportPrefixAppendsFixedDirsAfterExistingPath() {
    // Appending (via `${PATH:+$PATH:}`) keeps an rc-resolvable tool's own
    // precedence: the user's PATH comes first, the fixed dirs are a fallback.
    let prefix = WellKnownToolDirectories.pathExportPrefix
    #expect(prefix.hasPrefix("export PATH=\"${PATH:+$PATH:}\""))
    #expect(prefix.hasSuffix("; "))
    let existingPathIndex = prefix.range(of: "${PATH:+$PATH:}")?.lowerBound
    let brewIndex = prefix.range(of: "/home/linuxbrew/.linuxbrew/bin")?.lowerBound
    #expect(existingPathIndex != nil && brewIndex != nil && existingPathIndex! < brewIndex!)
  }

  @Test func pathExportPrefixGuardsEmptyPathAndUnsetHome() throws {
    // Exercise the guards, not just the idioms: run the export under an empty
    // PATH and unset HOME, then read PATH back. A leading colon would silently
    // put the CWD on PATH, and a bare `/.linuxbrew/bin` would resolve from root.
    let prefix = WellKnownToolDirectories.pathExportPrefix
    let resolved = try Self.runSh(
      "unset HOME; PATH=''; " + prefix + #"printf '%s' "$PATH""#)
    #expect(!resolved.hasPrefix(":"))
    #expect(!resolved.contains(":/.linuxbrew/bin"))
    #expect(!resolved.contains("$HOME"))  // no per-user dirs survive an unset HOME.
    #expect(resolved.hasPrefix("/opt/homebrew/bin"))
  }

  @Test func pathExportPrefixIsValidPosixSh() throws {
    // `sh -n` catches an unbalanced quote a golden-string rewrite could smuggle
    // in. The prefix must parse both standalone and spliced ahead of a command.
    for script in [
      WellKnownToolDirectories.pathExportPrefix + "true",
      WellKnownToolDirectories.pathExportPrefix + "command -v zmx >/dev/null 2>&1",
    ] {
      let check = Process()
      check.executableURL = URL(fileURLWithPath: "/bin/sh")
      check.arguments = ["-n", "-c", script]
      try check.run()
      check.waitUntilExit()
      #expect(check.terminationStatus == 0, "not valid sh: \(script)")
    }
  }

  /// Runs `script` under `/bin/sh -c` and returns its stdout.
  private static func runSh(_ script: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(bytes: data, encoding: .utf8) ?? ""
  }
}

struct RemoteHostTests {
  @Test func bareAliasHasNoUserOrPortOptions() {
    let host = RemoteHost(alias: "devbox")
    #expect(host.sshDestination == "devbox")
    #expect(host.sshOptionArguments.isEmpty)
  }

  @Test func usernameAndPortProjectIntoDestinationAndOptions() {
    let host = RemoteHost(alias: "box", username: "alice", port: 2222)
    #expect(host.sshDestination == "alice@box")
    #expect(host.sshOptionArguments == ["-p", "2222"])
  }

  @Test func emptyUsernameFallsBackToBareAlias() {
    let host = RemoteHost(alias: "box", username: "")
    #expect(host.sshDestination == "box")
  }

  @Test func hasNonDefaultPortFoldsDefaultAndUnspecifiedToFalse() {
    #expect(RemoteHost(alias: "box", port: 22).hasNonDefaultPort == false)
    #expect(RemoteHost(alias: "box", port: nil).hasNonDefaultPort == false)
    #expect(RemoteHost(alias: "box", port: 2222).hasNonDefaultPort == true)
  }

  @Test func sshURLAuthorityLeavesPlainInputsUnchanged() {
    #expect(RemoteHost(alias: "host").sshURLAuthority == "host")
    #expect(RemoteHost(alias: "host", username: "me").sshURLAuthority == "me@host")
    #expect(RemoteHost(alias: "host", username: "me", port: 2222).sshURLAuthority == "me@host:2222")
  }

  @Test func sshURLAuthorityKeepsExplicitDefaultPort() {
    // An explicit port 22 is preserved (matching `sshOptionArguments`' `-p 22`);
    // only a `nil` port is elided.
    #expect(RemoteHost(alias: "host", port: 22).sshURLAuthority == "host:22")
    #expect(RemoteHost(alias: "host").sshURLAuthority == "host")
  }

  @Test func sshURLAuthorityPercentEncodesSpecialCharacters() {
    #expect(RemoteHost(alias: "host", username: "a b").sshURLAuthority == "a%20b@host")
    #expect(RemoteHost(alias: "host", username: "a@b:c").sshURLAuthority == "a%40b%3Ac@host")
    #expect(RemoteHost(alias: "ho st", username: "me").sshURLAuthority == "me@ho%20st")
  }

  @Test func sshURLAuthorityBracketsIPv6HostWithUnencodedBrackets() {
    #expect(RemoteHost(alias: "::1").sshURLAuthority == "[::1]")
    #expect(RemoteHost(alias: "::1", username: "me", port: 2200).sshURLAuthority == "me@[::1]:2200")
  }

  @Test func sshURLAuthorityAppendsNonDefaultPortAfterEncodingUserAndHost() {
    #expect(RemoteHost(alias: "ho st", username: "a b", port: 2222).sshURLAuthority == "a%20b@ho%20st:2222")
  }

  @Test func sshURLAuthorityEncodesEmbeddedAtSoItCannotForgeAuthority() {
    #expect(RemoteHost(alias: "host", username: "me@evil").sshURLAuthority == "me%40evil@host")
  }

  @Test func sshURLAuthorityEncodesHostWhenUserIsAbsent() {
    #expect(RemoteHost(alias: "ho st").sshURLAuthority == "ho%20st")
  }

  @Test func sshURLAuthorityEncodesStructurallyDangerousUsernameCharacters() {
    #expect(RemoteHost(alias: "host", username: "a/b?c#d").sshURLAuthority == "a%2Fb%3Fc%23d@host")
  }
}

struct SSHCommandTests {
  @Test func shellQuoteWrapsAndEscapesSingleQuotes() {
    #expect(SSHCommand.shellQuote("echo hi") == "'echo hi'")
    #expect(SSHCommand.shellQuote("echo 'hi'") == "'echo '\\''hi'\\'''")
  }

  @Test func remoteCommandWithoutWorkingDirectoryQuotesEachToken() {
    let command = SSHCommand.remoteCommand(
      executable: "git",
      arguments: ["status", "--short"],
      workingDirectory: nil
    )
    #expect(command == "'git' 'status' '--short'")
  }

  @Test func remoteCommandWithWorkingDirectoryPrependsCdAndExec() {
    let command = SSHCommand.remoteCommand(
      executable: "/usr/bin/env",
      arguments: ["git", "status"],
      workingDirectory: URL(fileURLWithPath: "/tmp/repo")
    )
    #expect(command == "cd -- '/tmp/repo' && exec '/usr/bin/env' 'git' 'status'")
  }

  @Test func loginShellWrappedExecsLoginShellWithQuotedScript() {
    #expect(SSHCommand.loginShellWrapped("zmx attach s") == "exec \"$SHELL\" -l -c 'zmx attach s'")
    #expect(SSHCommand.loginShellWrapped("echo 'hi'") == "exec \"$SHELL\" -l -c 'echo '\\''hi'\\'''")
  }

  @Test func loginShellWrappedQuotesEachPositionalArgumentSeparately() {
    // A payload containing a single quote and a space must ride as a quoted positional arg,
    // never interpolated into the script text.
    #expect(
      SSHCommand.loginShellWrapped("$0 \"$@\"", positionalArguments: ["claude", "it's a test"])
        == "exec \"$SHELL\" -l -c '$0 \"$@\"' 'claude' 'it'\\''s a test'"
    )
  }

  @Test func loginShellWrappedPrefixesEnvironmentBeforeLoginShell() {
    // Sorted, each value quoted; the `env` prefix sets the vars before `$SHELL`
    // so the login shell inherits them before sourcing its profile.
    #expect(
      SSHCommand.loginShellWrapped(
        "$0 \"$@\"",
        positionalArguments: ["claude"],
        environment: ["SUPACODE_SCRIPT_KIND": "run", "SUPACODE_BLOCKING_SCRIPT": "1"]
      ) == "exec env SUPACODE_BLOCKING_SCRIPT='1' SUPACODE_SCRIPT_KIND='run' \"$SHELL\" -l -c '$0 \"$@\"' 'claude'"
    )
  }

  @Test func loginShellWrappedWithEmptyEnvironmentHasNoEnvPrefix() {
    #expect(
      SSHCommand.loginShellWrapped("$0", positionalArguments: ["x"], environment: [:])
        == "exec \"$SHELL\" -l -c '$0' 'x'"
    )
  }

  /// The fixed control-option argv every ssh invocation starts with. Keepalives
  /// live here so any ControlMaster, whichever path creates it, detects a dead
  /// connection.
  private static let controlOptionTokens: [String] = [
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=~/.ssh/supacode-%C",
    "-o", "ControlPersist=10m",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=3",
  ]

  @Test func invocationWrapsRemoteCommandInLoginShellAfterMultiplexingOptions() {
    let result = SSHCommand.invocation(
      host: RemoteHost(alias: "devbox"),
      executable: "/usr/bin/env",
      arguments: ["git", "-C", "/tmp/repo", "status"],
      workingDirectory: URL(fileURLWithPath: "/tmp/repo")
    )
    #expect(result.executableURL == URL(fileURLWithPath: "/usr/bin/ssh"))
    let expectedScript = SSHCommand.remoteCommand(
      executable: "/usr/bin/env",
      arguments: ["git", "-C", "/tmp/repo", "status"],
      workingDirectory: URL(fileURLWithPath: "/tmp/repo")
    )
    #expect(
      result.arguments == Self.controlOptionTokens + [
        "devbox",
        SSHCommand.loginShellWrapped(expectedScript),
      ]
    )
    // The wrapped arg actually carries the git invocation under a login shell.
    #expect(result.arguments.last?.hasPrefix("exec \"$SHELL\" -l -c ") == true)
    #expect(result.arguments.last?.contains("git") == true)
  }

  @Test func invocationAllocatesTTYAndForwardsPortWhenRequested() {
    let result = SSHCommand.invocation(
      host: RemoteHost(alias: "box", username: "alice", port: 2222),
      executable: "zmx",
      arguments: ["ls"],
      workingDirectory: nil,
      allocateTTY: true
    )
    #expect(
      result.arguments == Self.controlOptionTokens + [
        "-tt",
        "-p", "2222",
        "alice@box",
        SSHCommand.loginShellWrapped("'zmx' 'ls'"),
      ]
    )
  }

  /// The fixed option prefix of every interactive `commandLine`.
  private static let commandLinePrefix =
    "/usr/bin/ssh " + controlOptionTokens.joined(separator: " ") + " -o ConnectTimeout=30 -tt devbox "

  @Test func commandLineWrapsRemoteCommandInLoginShellQuotedForLocalShell() {
    let line = SSHCommand.commandLine(
      host: RemoteHost(alias: "devbox"),
      remoteCommand: "zmx attach supa-x"
    )
    let expectedTail = SSHCommand.shellQuote(SSHCommand.loginShellWrapped("zmx attach supa-x"))
    #expect(line == Self.commandLinePrefix + expectedTail)
  }

  @Test func commandLineForwardsPositionalArgumentsQuotedForLocalShell() {
    // A payload containing a single quote and a space rides as a positional arg, double-quoted
    // for the local shell on top of the inner per-arg quoting.
    let line = SSHCommand.commandLine(
      host: RemoteHost(alias: "devbox"),
      remoteScript: "$0 \"$@\"",
      positionalArguments: ["claude", "it's a test"]
    )
    let expectedTail = SSHCommand.shellQuote(
      SSHCommand.loginShellWrapped("$0 \"$@\"", positionalArguments: ["claude", "it's a test"])
    )
    #expect(line == Self.commandLinePrefix + expectedTail)
  }

  @Test func controlOptionsCarryKeepalivesForAnyMultiplexOwner() {
    // Keepalives belong to whichever process is the ControlMaster, so they
    // ride `controlOptions` (every path), not a per-caller option set.
    #expect(SSHCommand.controlOptions() == Self.controlOptionTokens)
    #expect(!SSHCommand.backgroundProbeOptions.contains("ServerAliveInterval=5"))
    #expect(SSHCommand.interactiveOptions == ["-o", "ConnectTimeout=30"])
    // No `BatchMode` on the interactive line so first-connect auth prompts work.
    let line = SSHCommand.commandLine(host: RemoteHost(alias: "devbox"), remoteCommand: "true")
    #expect(!line.contains("BatchMode"))
  }
}

struct ZmxAttachRemoteTests {
  private let surfaceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
  private var hostSessionID: String { ZmxSessionID.make(surfaceID: surfaceID) }
  private let localZmx = "/Applications/Supacode.app/Contents/MacOS/zmx"
  private static let defaultShell = "cd '/home/dev/repo/wt-1' 2>/dev/null; exec \"$SHELL\" -l"

  private func makeLaunch(
    host: RemoteHost = RemoteHost(alias: "devbox"),
    userCommand: String? = nil,
    defaultCommand: String? = defaultShell,
    hostPersistenceEnabled: Bool = true
  ) -> ZmxAttach.RemoteSurfaceLaunch {
    ZmxAttach.RemoteSurfaceLaunch(
      host: host,
      surfaceID: surfaceID,
      userCommand: userCommand,
      defaultCommand: defaultCommand,
      hostPersistenceEnabled: hostPersistenceEnabled
    )
  }

  private var surfaceExport: String {
    "export SUPACODE_SURFACE_ID='\(surfaceID.uuidString)'; "
  }

  @Test func connectScriptWithoutUserCommandAttachesLoginShellSession() {
    // Interactive surface: the session runs the worktree default (cd + login
    // shell) behind the banners, and a failed attach falls through to a
    // fresh default shell with a visible notice instead of an instant close.
    let script = ZmxAttach.remoteConnectScript(makeLaunch())
    #expect(
      script.hasPrefix(
        surfaceExport + ZmxAttach.brewPathPrefix + "if command -v zmx >/dev/null 2>&1; then "))
    #expect(
      script.contains(
        "zmx attach \(hostSessionID) \"$SHELL\" -l -c "
          + ZmxAttach.shellQuote(ZmxAttach.betaBanner + ZmxAttach.persistentBanner + Self.defaultShell) + "\n"
      )
    )
    #expect(script.contains("[ \"$supa_rc\" -eq 0 ] && exit 0"))
    #expect(script.contains("zmx attach exited with status %s"))
    #expect(script.contains(ZmxAttach.betaBanner + ZmxAttach.zmxInstallHintBanner))
    #expect(script.hasSuffix("fi\n" + ZmxAttach.loginShellRun(Self.defaultShell)))
    // The banner rides inside the session command (an attach redraw would
    // swallow anything printed before `zmx attach`).
    #expect(!script.contains(ZmxAttach.persistentBanner + "zmx attach"))
    // Env export precedes the attach, so the session inherits it on create.
    let exportIndex = script.range(of: "export SUPACODE_SURFACE_ID")?.lowerBound
    let attachIndex = script.range(of: "zmx attach")?.lowerBound
    #expect(exportIndex != nil && attachIndex != nil && exportIndex! < attachIndex!)
  }

  @Test func connectScriptRunsUserCommandThroughLoginShellInsideSession() {
    // The session command rides `"$SHELL" -l -c`, not `/bin/sh -c`, so
    // bash/zsh-isms keep working on dash-as-/bin/sh hosts.
    let script = ZmxAttach.remoteConnectScript(makeLaunch(userCommand: "echo 'hi'; claude --resume"))
    #expect(
      script.contains(
        "zmx attach \(hostSessionID) \"$SHELL\" -l -c "
          + ZmxAttach.shellQuote(ZmxAttach.betaBanner + ZmxAttach.persistentBanner + "echo 'hi'; claude --resume")
          + "\n"
      )
    )
    // The no-zmx fallthrough runs the user command directly.
    #expect(script.hasSuffix("fi\n" + ZmxAttach.loginShellRun("echo 'hi'; claude --resume")))
    // The failed-attach fallthrough lands in a fresh default shell: attach
    // can fail after the session started, and a one-shot command must never
    // spawn a second concurrent copy.
    #expect(script.contains(ZmxAttach.loginShellRun(Self.defaultShell) + "\nelse "))
    #expect(script.ranges(of: ZmxAttach.loginShellRun("echo 'hi'; claude --resume")).count == 1)
  }

  @Test func connectScriptWithoutHostPersistenceKeepsFlatShape() {
    #expect(
      ZmxAttach.remoteConnectScript(makeLaunch(userCommand: "claude --resume", hostPersistenceEnabled: false))
        == surfaceExport + ZmxAttach.betaBanner + ZmxAttach.loginShellRun("claude --resume")
    )
    #expect(
      ZmxAttach.remoteConnectScript(makeLaunch(defaultCommand: nil, hostPersistenceEnabled: false))
        == surfaceExport + ZmxAttach.betaBanner + ZmxAttach.loginShellRun("exec \"$SHELL\" -l")
    )
  }

  @Test func connectScriptIgnoresWhitespaceUserCommand() {
    #expect(
      ZmxAttach.remoteConnectScript(makeLaunch(userCommand: "  \n"))
        == ZmxAttach.remoteConnectScript(makeLaunch())
    )
  }

  @Test func connectScriptPrependsBrewPathAheadOfZmxLookup() {
    // Regression for issue #671: a non-interactive login shell never sources
    // the interactive rc file where Homebrew's Linux installer puts
    // `brew shellenv`, so brew-installed zmx is off PATH. The connect script
    // must augment PATH with the brew prefixes before `command -v zmx`, and
    // the surface-id export must still precede it so the session inherits it.
    let script = ZmxAttach.remoteConnectScript(makeLaunch())
    #expect(script.contains(ZmxAttach.brewPathPrefix + "if command -v zmx"))
    let pathIndex = script.range(of: "export PATH=")?.lowerBound
    let lookupIndex = script.range(of: "command -v zmx")?.lowerBound
    #expect(pathIndex != nil && lookupIndex != nil && pathIndex! < lookupIndex!)
    #expect(script.contains("/home/linuxbrew/.linuxbrew/bin"))
    #expect(script.contains("$HOME/.linuxbrew/bin"))
    #expect(script.contains("/opt/homebrew/bin"))
  }

  @Test func reconnectScriptReattachesExistingSessionAndNeverRerunsUserCommand() {
    // Reconnects are attach-only: a session that ended while disconnected
    // closes the pane (exit 0, with a notice) instead of re-running a
    // one-shot command. The suffix-anchored grep matches names prefixed by a
    // host-side ZMX_SESSION_PREFIX.
    let script = ZmxAttach.remoteReconnectScript(makeLaunch(userCommand: "./deploy.sh"))
    // The brew PATH augmentation precedes the zmx lookup here too (issue #671).
    #expect(
      script.hasPrefix(
        surfaceExport + ZmxAttach.brewPathPrefix + "if command -v zmx >/dev/null 2>&1; then "))
    #expect(script.contains("if zmx list --short 2>/dev/null | grep -q '\(hostSessionID)$'; then "))
    #expect(script.contains("exec zmx attach \(hostSessionID)\n"))
    #expect(script.contains(ZmxAttach.sessionEndedNotice + "exit 0\n"))
    #expect(!script.contains("deploy.sh"))
    // The no-zmx fallback drops into the default shell with a notice.
    #expect(script.contains(ZmxAttach.reconnectShellNotice))
    #expect(script.hasSuffix(ZmxAttach.loginShellRun(Self.defaultShell)))
  }

  @Test func reconnectScriptWithoutHostPersistenceDropsToDefaultShell() {
    let script = ZmxAttach.remoteReconnectScript(
      makeLaunch(userCommand: "./deploy.sh", hostPersistenceEnabled: false))
    #expect(script == surfaceExport + ZmxAttach.reconnectShellNotice + ZmxAttach.loginShellRun(Self.defaultShell))
  }

  @Test func posixShellWrappedKeepsLoginShellParseSurfaceTrivial() {
    // The login shell (possibly fish/csh) only parses one portable line; the
    // POSIX if/fi script runs in /bin/sh.
    #expect(
      ZmxAttach.posixShellWrapped("if true; then echo 'a'; fi")
        == "exec /bin/sh -c 'if true; then echo '\\''a'\\''; fi'"
    )
  }

  @Test func loginShellRunExecsLoginShellWithQuotedCommand() {
    // Pins the wrapper itself: every consumer golden composes through it, so
    // only a literal expectation catches it degrading to the /bin/sh layer.
    #expect(ZmxAttach.loginShellRun("echo 'hi'") == "exec \"$SHELL\" -l -c 'echo '\\''hi'\\'''")
  }

  @Test func bannerConstantsAreSelfTerminatedPrintfStatements() async throws {
    // Every banner must be a complete `printf '...'; ` statement: script
    // builders concatenate them blindly, and a missing trailing separator
    // would merge the banner into the next command by word concatenation,
    // which `sh -n` cannot catch inside quoted session commands.
    let banners = [
      ZmxAttach.betaBanner,
      ZmxAttach.persistentBanner,
      ZmxAttach.zmxInstallHintBanner,
      ZmxAttach.reconnectShellNotice,
      ZmxAttach.sessionEndedNotice,
    ]
    for banner in banners {
      #expect(banner.hasPrefix("printf '"), "not a printf: \(banner)")
      #expect(banner.hasSuffix("'; "), "missing statement terminator: \(banner)")
      #expect(!banner.dropFirst("printf '".count).dropLast("'; ".count).contains("'"), "unescaped quote: \(banner)")
    }
    // The exact inner session-command composition executes cleanly and
    // passes the trailing command's exit status through.
    let run = Process()
    run.executableURL = URL(fileURLWithPath: "/bin/sh")
    run.arguments = ["-c", ZmxAttach.betaBanner + ZmxAttach.persistentBanner + "exit 42"]
    run.standardOutput = FileHandle.nullDevice
    run.standardError = FileHandle.nullDevice
    try await run.runToExit()
    #expect(run.terminationStatus == 42)
  }

  @Test func reconnectLoopRunsConnectOnceThenAttachOnlyRetriesOn255() {
    let connect = "/usr/bin/ssh -tt devbox 'connect'"
    let reconnect = "/usr/bin/ssh -tt devbox 'reconnect'"
    let script = SSHReconnectLoop.script(connect: connect, reconnect: reconnect)
    #expect(
      script
        == "trap 'exit 130' INT; "
        + connect
        + "; supa_rc=$?; [ \"$supa_rc\" -ne 255 ] && exit \"$supa_rc\"; "
        + "supa_delay=1; while :; do "
        + #"printf '\033[1;33m── Connection failed (ssh exit 255). Retrying in %ss. "#
        + #"Press Ctrl-C to stop. ──\033[0m\r\n' "$supa_delay"; "#
        + "sleep \"$supa_delay\"; supa_delay=$((supa_delay * 2)); "
        + "[ \"$supa_delay\" -gt 15 ] && supa_delay=15; "
        + reconnect
        + "; supa_rc=$?; [ \"$supa_rc\" -ne 255 ] && exit \"$supa_rc\"; done"
    )
    #expect(script.ranges(of: connect).count == 1)
    #expect(script.ranges(of: reconnect).count == 1)
  }

  @Test func reconnectLoopScriptsAreValidShAndPassExitCodesThrough() async throws {
    // `sh -n` catches an unbalanced quote or broken test that a golden-string
    // rewrite could smuggle in; the run asserts non-255 passthrough without
    // ever reaching `sleep`.
    let launch = makeLaunch(userCommand: "echo 'x'")
    let loop = SSHReconnectLoop.script(
      connect: "sh -c 'exit 7'",
      reconnect: "sh -c 'exit 0'"
    )
    let scripts = [
      loop,
      ZmxAttach.remoteConnectScript(launch),
      ZmxAttach.remoteReconnectScript(launch),
    ]
    for script in scripts {
      let check = Process()
      check.executableURL = URL(fileURLWithPath: "/bin/sh")
      check.arguments = ["-n", "-c", script]
      try await check.runToExit()
      #expect(check.terminationStatus == 0, "sh -n rejected: \(script)")
    }
    let run = Process()
    run.executableURL = URL(fileURLWithPath: "/bin/sh")
    run.arguments = ["-c", loop]
    run.standardOutput = FileHandle.nullDevice
    run.standardError = FileHandle.nullDevice
    try await run.runToExit()
    #expect(run.terminationStatus == 7)
  }

  @Test func buildRemoteCommandWrapsReconnectLoopInLocalZmxWithoutReverseForward() {
    let launch = makeLaunch()
    let connectLine = SSHCommand.commandLine(
      host: launch.host,
      remoteCommand: ZmxAttach.posixShellWrapped(ZmxAttach.remoteConnectScript(launch))
    )
    let reconnectLine = SSHCommand.commandLine(
      host: launch.host,
      remoteCommand: ZmxAttach.posixShellWrapped(ZmxAttach.remoteReconnectScript(launch))
    )
    let command = ZmxAttach.buildRemoteCommand(launch, localZmxExecutablePath: localZmx)
    // Local zmx owns the session; its child process is the reconnect loop
    // around both ssh lines. Local and host sessions share the name.
    #expect(
      command
        == ZmxAttach.buildCommand(
          executablePath: localZmx,
          sessionID: hostSessionID,
          userCommand: SSHReconnectLoop.script(connect: connectLine, reconnect: reconnectLine)
        )
    )
    #expect(command.contains("attach \(hostSessionID)"))
    #expect(command.contains(localZmx))
    #expect(command.contains("SUPACODE_SURFACE_ID="))
    // Presence rides the OSC stream now, with no reverse socket / remote socket path.
    #expect(!command.contains("-R "))
    #expect(!command.contains("SUPACODE_SOCKET_PATH"))
  }

  @Test func buildRemoteCommandFallsBackToBareReconnectLoopWhenLocalZmxUnavailable() {
    let launch = makeLaunch(hostPersistenceEnabled: false)
    let command = ZmxAttach.buildRemoteCommand(launch, localZmxExecutablePath: nil)
    // No local zmx: still a reconnect loop, just without quit persistence.
    #expect(
      command
        == SSHReconnectLoop.script(
          connect: SSHCommand.commandLine(
            host: launch.host,
            remoteCommand: ZmxAttach.posixShellWrapped(ZmxAttach.remoteConnectScript(launch))
          ),
          reconnect: SSHCommand.commandLine(
            host: launch.host,
            remoteCommand: ZmxAttach.posixShellWrapped(ZmxAttach.remoteReconnectScript(launch))
          )
        )
    )
    #expect(!command.contains("zmx attach"))
  }

  @Test func buildRemoteCommandForwardsUsernameAndPort() {
    let command = ZmxAttach.buildRemoteCommand(
      makeLaunch(host: RemoteHost(alias: "box", username: "alice", port: 2222)),
      localZmxExecutablePath: localZmx
    )
    #expect(command.contains("-p 2222 alice@box "))
  }

  @Test func remoteKillInvocationGuardsMissingZmxAndRidesProbeOptions() throws {
    let result = ZmxAttach.remoteKillInvocation(
      host: RemoteHost(alias: "box", username: "alice", port: 2222),
      sessionID: "supa-x"
    )
    // The `-c` script augments PATH with the brew dirs (#671) before the zmx
    // guard. Compose the expected argument through the same quoting helpers
    // rather than hand-escaping: `pathExportPrefix` embeds single quotes, so a
    // literal golden would be fragile without adding review value.
    let killScript =
      ZmxAttach.brewPathPrefix
      + "command -v zmx >/dev/null 2>&1 || exit 0; zmx kill supa-x; "
      + "! zmx list --short 2>/dev/null | grep -q 'supa-x$'"
    #expect(result.executableURL == URL(fileURLWithPath: "/usr/bin/ssh"))
    #expect(
      result.arguments == [
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=~/.ssh/supacode-%C",
        "-o", "ControlPersist=10m",
        "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=3",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-p", "2222",
        "alice@box",
        SSHCommand.loginShellWrapped(
          SSHCommand.remoteCommand(
            executable: "/bin/sh", arguments: ["-c", killScript], workingDirectory: nil)
        ),
      ]
    )
    // Guard the intent directly: brew PATH precedes the zmx guard, and the
    // spliced `-c` script parses as POSIX sh (symmetry with connect/reconnect).
    #expect(killScript.hasPrefix("export PATH="))
    let check = Process()
    check.executableURL = URL(fileURLWithPath: "/bin/sh")
    check.arguments = ["-n", "-c", killScript]
    try check.run()
    check.waitUntilExit()
    #expect(check.terminationStatus == 0, "kill script not valid sh: \(killScript)")
  }
}
