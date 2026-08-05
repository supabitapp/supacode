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

  /// The adversarial tokens the quoting contract has to survive. Every one is a
  /// byte the remote login shell would otherwise rewrite, split, or expand.
  static let quotingContractTokens = [
    "plain",
    "",
    "it's",
    #"a\b"#,
    #"trailing\"#,
    #"double\\backslash"#,
    #"'"#,
    #"\"#,
    #"it's\literal"#,
    "spaced out",
    "$HOME",
    "`id`",
    "$(id)",
    "*.txt",
    "~root",
    "a;rm -rf /",
    "line1\nline2",
    "tab\there",
    "é中🐟",
  ]

  @Test func loginShellQuoteEmitsSpansEveryLoginShellDecodesIdentically() {
    // Pinned literally: the fish round-trips below all pair a backslash with
    // other characters, so they stay green if the escape arms degrade.
    #expect(SSHCommand.loginShellQuote("") == "''")
    #expect(SSHCommand.loginShellQuote("plain") == "'plain'")
    #expect(SSHCommand.loginShellQuote("it's") == "'it'\"'\"'s'")
    #expect(SSHCommand.loginShellQuote(#"a\b"#) == #"'a'\\'b'"#)
    #expect(SSHCommand.loginShellQuote(#"trailing\"#) == #"'trailing'\\''"#)
    #expect(SSHCommand.loginShellQuote(#"\"#) == #"''\\''"#)
    #expect(SSHCommand.loginShellQuote("'") == "''\"'\"''")
  }

  @Test(arguments: LoginShellProbe.quotingContractShells)
  func loginShellQuoteRoundTripsEveryTokenUnder(_ shell: String) async throws {
    // Nested twice: production re-quotes an already-quoted payload (the
    // terminal-compatibility wrap around the login-shell wrap), which is where
    // a backslash left bare inside a single-quoted span gets eaten.
    try await LoginShellProbe.withTemporaryDirectory("login-shell-quote") { root in
      for token in Self.quotingContractTokens {
        // Delimited, so an empty token is distinguishable from a command that
        // silently produced nothing while exiting 0.
        let inner =
          "/bin/echo -n '<'; /bin/echo -n " + SSHCommand.loginShellQuote(token)
          + "; /bin/echo -n '>'"
        let result = try await LoginShellProbe.run(
          shell,
          command: "eval " + SSHCommand.loginShellQuote(inner),
          configRoot: root
        )
        #expect(result.status == 0, "\(shell) rejected \(token.debugDescription): \(result.stderr)")
        #expect(result.stdout == "<\(token)>", "\(shell) changed \(token.debugDescription)")
        #expect(result.shellDiagnostics.isEmpty, "\(shell): \(result.shellDiagnostics)")
      }
    }
  }

  @Test func fishLoginShellExecutesRemoteCommandWithoutChangingTokens() async throws {
    try await LoginShellProbe.withTemporaryDirectory("fish-command") { temporaryRoot in
      let workingDirectory = temporaryRoot.appending(path: #"working:it's\literal"#)
      let executableURL = temporaryRoot.appending(path: #"shell:it's\literal"#)
      try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        at: executableURL,
        withDestinationURL: URL(fileURLWithPath: "/bin/sh")
      )

      let argument = #"argument:it's\literal"#
      let remoteCommand = SSHCommand.remoteCommand(
        executable: executableURL.path,
        arguments: [
          "-c",
          #"printf '%s\n' "$PWD" "$1""#,
          "supacode-test",
          argument,
        ],
        workingDirectory: workingDirectory
      )
      let result = try await LoginShellProbe.run(
        "fish",
        command: SSHCommand.loginShellWrapped(remoteCommand),
        configRoot: temporaryRoot.appending(path: "config")
      )

      #expect(result.status == 0, "Fish rejected the remote command: \(result.stderr)")
      #expect(result.shellDiagnostics.isEmpty, "\(result.shellDiagnostics)")
      #expect(result.stdout == "\(workingDirectory.path)\n\(argument)\n")
    }
  }

  @Test func loginShellWrappedExecsLoginShellWithQuotedScript() {
    #expect(SSHCommand.loginShellWrapped("zmx attach s") == "exec \"$SHELL\" -l -c 'zmx attach s'")
    #expect(SSHCommand.loginShellWrapped("echo 'hi'") == "exec \"$SHELL\" -l -c 'echo '\"'\"'hi'\"'\"''")
  }

  @Test func loginShellWrappedQuotesEachPositionalArgumentSeparately() {
    // A payload containing a single quote and a space must ride as a quoted positional arg,
    // never interpolated into the script text.
    #expect(
      SSHCommand.loginShellWrapped("$0 \"$@\"", positionalArguments: ["claude", "it's a test"])
        == "exec \"$SHELL\" -l -c '$0 \"$@\"' 'claude' 'it'\"'\"'s a test'"
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

  @Test func loginShellWrappedPosixScriptRunsTheScriptUnderSh() {
    // Verified independently of the builder helpers: if this ever degraded back
    // to a bare login-shell `-c`, the self-referential `commandLine` assertions
    // below would not notice, but these literals break.
    let wrapped = SSHCommand.loginShellWrappedPosixScript(
      "$0 \"$@\"",
      positionalArguments: ["claude"],
      environment: ["SUPACODE_BLOCKING_SCRIPT": "1"]
    )
    // The `sh` layer, not the login shell, is what receives the positionals, so
    // `claude` must sit outside the script's own quoted span.
    #expect(
      wrapped == "exec env SUPACODE_BLOCKING_SCRIPT='1' \"$SHELL\" -l -c "
        + SSHCommand.loginShellQuote("exec /bin/sh -c '$0 \"$@\"' 'claude'")
    )
  }

  @Test func fishLoginShellReceivesArgumentsAndEnvironmentByteForByte() async throws {
    // `$argv`, not `$1`: fish has no numbered positionals and expands `$1` to an
    // empty string, which is why a script reading `$1` goes through
    // `loginShellWrappedPosixScript` instead.
    try await LoginShellProbe.withTemporaryDirectory("fish-arguments") { root in
      let argument = #"argument:it's\literal"#
      let environmentValue = #"environment:it's\literal"#
      let result = try await LoginShellProbe.run(
        "fish",
        command: SSHCommand.loginShellWrapped(
          #"printf '%s\n' "$SUPACODE_TEST_VALUE" "$argv[1]" "$argv[2]""#,
          positionalArguments: ["supacode-test", argument],
          environment: ["SUPACODE_TEST_VALUE": environmentValue]
        ),
        configRoot: root
      )

      #expect(result.status == 0, "Fish rejected the login-shell wrapper: \(result.stderr)")
      #expect(result.shellDiagnostics.isEmpty, "\(result.shellDiagnostics)")
      #expect(result.stdout == "\(environmentValue)\nsupacode-test\n\(argument)\n")
    }
  }

  @Test(arguments: LoginShellProbe.quotingContractShells)
  func loginShellWrappedPosixScriptBindsNumberedPositionalsUnder(_ shell: String) async throws {
    // The blocking-script channel: the user script rides as `$1` through a
    // login shell that may not have numbered positionals at all.
    try await LoginShellProbe.withTemporaryDirectory("posix-script-\(shell)") { root in
      let payload = #"payload:it's\literal"#
      let result = try await LoginShellProbe.run(
        shell,
        command: SSHCommand.loginShellWrappedPosixScript(
          #"printf '%s\n' "$0" "$1" "$SUPACODE_TEST_VALUE""#,
          positionalArguments: ["supacode-blocking", payload],
          environment: ["SUPACODE_TEST_VALUE": payload]
        ),
        configRoot: root
      )

      #expect(result.status == 0, "\(shell) rejected the POSIX-script wrapper: \(result.stderr)")
      #expect(result.shellDiagnostics.isEmpty, "\(shell): \(result.shellDiagnostics)")
      #expect(result.stdout == "supacode-blocking\n\(payload)\n\(payload)\n")
    }
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

  @Test func terminalCompatibilityFallsBackOnlyWhenGhosttyTerminfoIsMissing() async throws {
    // `term: nil` unsets TERM; the `${TERM:-}` guard must leave it untouched
    // (no spurious `infocmp` fork, no fallback), same for an empty TERM.
    let scenarios = [
      (term: "xterm-ghostty", infocmpExit: 0, expected: "xterm-ghostty"),
      (term: "xterm-ghostty", infocmpExit: 1, expected: "xterm-256color"),
      (term: "xterm-ghostty", infocmpExit: 127, expected: "xterm-256color"),
      (term: "screen-256color", infocmpExit: 1, expected: "screen-256color"),
      (term: "", infocmpExit: 1, expected: ""),
      (term: nil, infocmpExit: 1, expected: ""),
    ]

    for scenario in scenarios {
      let termSetup =
        scenario.term.map { "TERM=\(SSHCommand.shellQuote($0)); export TERM; " } ?? "unset TERM; "
      let process = Process()
      let output = Pipe()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = [
        "-c",
        "infocmp() { return \(scenario.infocmpExit); }; "
          + termSetup
          + SSHCommand.terminalCompatibilityPrelude
          + #"printf '%s' "${TERM:-}""#,
      ]
      process.standardOutput = output
      try await process.runToExit()

      let resolved = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
      #expect(process.terminationStatus == 0)
      #expect(resolved == scenario.expected)
    }
  }

  @Test func terminalCompatibleLoginShellCommandEmbedsFallbackPreludeAheadOfCommand() {
    // Verified independently of the builder helpers: if the wrapper ever
    // stopped injecting the prelude (silently no-op'ing the fix), these
    // literals break, whereas the self-referential `commandLine` assertions
    // below would not.
    let wrapped = SSHCommand.terminalCompatibleLoginShellCommand("exec \"$SHELL\" -l")
    #expect(wrapped.hasPrefix("exec /bin/sh -c "))
    #expect(wrapped.contains(#"[ "${TERM:-}" = xterm-ghostty ]"#))
    #expect(wrapped.contains("export TERM=xterm-256color"))
    #expect(wrapped.contains("exec \"$SHELL\" -l"))
  }

  @Test func terminalCompatibleLoginShellCommandIsValidPosixSh() async throws {
    let command = SSHCommand.terminalCompatibleLoginShellCommand(
      SSHCommand.loginShellWrapped("echo 'ready'")
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-n", "-c", command]
    try await process.runToExit()
    #expect(process.terminationStatus == 0, "sh -n rejected: \(command)")
  }

  @Test func terminalCompatibleLoginShellCommandRoundTripsSingleQuotedPayload() async throws {
    // The extra `shellQuote` layer must preserve a single-quote-bearing payload
    // through the local `/bin/sh -c` that runs the wrapped command.
    let wrapped = SSHCommand.terminalCompatibleLoginShellCommand(#"printf '%s' "it's here""#)
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", wrapped]
    process.standardOutput = output
    try await process.runToExit()

    let resolved = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    #expect(process.terminationStatus == 0)
    #expect(resolved == "it's here")
  }

  @Test func fishLoginShellExecutesTerminalCompatibleCommandWithoutChangingTokens() async throws {
    // The remote login shell parses the terminal-compatibility wrap itself, so
    // its quoting must survive fish: backslash-bearing tokens quoted by
    // `loginShellQuote` embed backslashes the POSIX-only `shellQuote` would let
    // fish rewrite inside single quotes.
    try await LoginShellProbe.withTemporaryDirectory("fish-term") { temporaryRoot in
      let workingDirectory = temporaryRoot.appending(path: #"working:it's\literal"#)
      try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

      let argument = #"argument:it's\literal"#
      let remoteCommand = SSHCommand.remoteCommand(
        executable: "/bin/sh",
        arguments: [
          "-c",
          #"printf '%s\n' "$PWD" "$1""#,
          "supacode-test",
          argument,
        ],
        workingDirectory: workingDirectory
      )
      // Pinned to the ghostty value so the `infocmp` half of the prelude runs
      // here, not just the probe's default `TERM`.
      let result = try await LoginShellProbe.run(
        "fish",
        command: SSHCommand.terminalCompatibleLoginShellCommand(
          SSHCommand.loginShellWrapped(remoteCommand)
        ),
        configRoot: temporaryRoot.appending(path: "config"),
        extraEnvironment: ["TERM": "xterm-ghostty"]
      )

      #expect(result.status == 0, "Fish rejected the wrapped command: \(result.stderr)")
      #expect(result.shellDiagnostics.isEmpty, "\(result.shellDiagnostics)")
      #expect(result.stdout == "\(workingDirectory.path)\n\(argument)\n")
    }
  }

  @Test func commandLineWrapsRemoteCommandInLoginShellQuotedForLocalShell() {
    let line = SSHCommand.commandLine(
      host: RemoteHost(alias: "devbox"),
      remoteCommand: "zmx attach supa-x"
    )
    let expectedTail = SSHCommand.shellQuote(
      SSHCommand.terminalCompatibleLoginShellCommand(
        SSHCommand.loginShellWrapped("zmx attach supa-x")
      )
    )
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
      SSHCommand.terminalCompatibleLoginShellCommand(
        SSHCommand.loginShellWrappedPosixScript(
          "$0 \"$@\"",
          positionalArguments: ["claude", "it's a test"]
        )
      )
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
    // The login shell (possibly fish) only parses one portable line; the
    // POSIX if/fi script runs in /bin/sh.
    #expect(
      SSHCommand.posixShellWrapped("if true; then echo 'a'; fi")
        == "exec /bin/sh -c 'if true; then echo '\"'\"'a'\"'\"'; fi'"
    )
  }

  @Test func fishLoginShellReceivesNestedPosixScriptByteForByte() async throws {
    try await LoginShellProbe.withTemporaryDirectory("fish-nested") { root in
      let script = #"""
        printf '%s\n' "single:'"
        printf '%s\n' 'osc:\033\\zmx'
        """#
      let result = try await LoginShellProbe.run(
        "fish",
        command: SSHCommand.loginShellWrapped(SSHCommand.posixShellWrapped(script)),
        configRoot: root
      )

      #expect(result.status == 0, "Fish rejected the nested remote command: \(result.stderr)")
      #expect(result.shellDiagnostics.isEmpty, "\(result.shellDiagnostics)")
      #expect(result.stdout == "single:'\nosc:\\033\\\\zmx\n")
    }
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
      remoteCommand: SSHCommand.posixShellWrapped(ZmxAttach.remoteConnectScript(launch))
    )
    let reconnectLine = SSHCommand.commandLine(
      host: launch.host,
      remoteCommand: SSHCommand.posixShellWrapped(ZmxAttach.remoteReconnectScript(launch))
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
    let loop = SSHReconnectLoop.script(
      connect: SSHCommand.commandLine(
        host: launch.host,
        remoteCommand: SSHCommand.posixShellWrapped(ZmxAttach.remoteConnectScript(launch))
      ),
      reconnect: SSHCommand.commandLine(
        host: launch.host,
        remoteCommand: SSHCommand.posixShellWrapped(ZmxAttach.remoteReconnectScript(launch))
      )
    )
    // No local zmx: still a reconnect loop, just without quit persistence, but
    // wrapped in `/bin/sh -c` so Ghostty's `exec -l <command>` leads with an
    // executable and not the loop's opening `trap` builtin (#737).
    #expect(command == "/bin/sh -c " + ZmxAttach.shellQuote(loop))
    #expect(command.hasPrefix("/bin/sh -c "))
    #expect(!command.contains("zmx attach"))
  }

  @Test func bareReconnectLoopSurvivesGhosttyExecLoginWrapping() async throws {
    // Ghostty runs a surface command as `bash -c "exec -l <command>"`, so it
    // must lead with an executable. `sh -n` confirms the fallback's outer
    // wrapper is balanced (it can't descend into the single-quoted inner loop;
    // that template is parse-checked in
    // `reconnectLoopScriptsAreValidShAndPassExitCodesThrough`). The benign runs
    // below then prove the `/bin/sh -c` prefix lets `exec -l` resolve an
    // executable, while the unwrapped loop still dies with `trap: not found`
    // (#737).
    let launch = makeLaunch(hostPersistenceEnabled: false)
    let command = ZmxAttach.buildRemoteCommand(launch, localZmxExecutablePath: nil)
    let parse = Process()
    parse.executableURL = URL(fileURLWithPath: "/bin/sh")
    parse.arguments = ["-n", "-c", command]
    try await parse.runToExit()
    #expect(parse.terminationStatus == 0, "sh -n rejected: \(command)")

    // A stand-in loop with connect lines that exit 0 (non-255, so the retry
    // body never runs) exercises the exact `bash -c "exec -l <command>"` shape
    // Ghostty applies, isolated from real ssh dialing.
    let benignLoop = SSHReconnectLoop.script(connect: "sh -c 'exit 0'", reconnect: "sh -c 'exit 0'")

    let wrapped = Process()
    wrapped.executableURL = URL(fileURLWithPath: "/bin/bash")
    wrapped.arguments = ["--noprofile", "--norc", "-c", "exec -l /bin/sh -c \(ZmxAttach.shellQuote(benignLoop))"]
    wrapped.standardOutput = FileHandle.nullDevice
    wrapped.standardError = FileHandle.nullDevice
    try await wrapped.runToExit()
    #expect(wrapped.terminationStatus == 0, "wrapped loop failed under exec -l")

    // Control: the unwrapped loop is exactly what broke #737.
    let bare = Process()
    bare.executableURL = URL(fileURLWithPath: "/bin/bash")
    bare.arguments = ["--noprofile", "--norc", "-c", "exec -l \(benignLoop)"]
    bare.standardOutput = FileHandle.nullDevice
    bare.standardError = FileHandle.nullDevice
    try await bare.runToExit()
    #expect(bare.terminationStatus == 127, "bare loop unexpectedly survived exec -l")
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
