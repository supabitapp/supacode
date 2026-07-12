import ComposableArchitecture
import Dependencies
import Foundation
import SupacodeSettingsShared

nonisolated private let zmxLogger = SupaLogger("Zmx")

/// Per-surface session-persistence wrapper. Surface commands are routed through
/// `zmx attach <id>` so the underlying shell survives app quit; on next launch
/// the same surface UUID re-attaches to the live daemon.
///
/// The client is intentionally cache-free: zmx itself is authoritative for
/// attach-vs-create, so we never gate setup-script firing on a stale local
/// snapshot of daemon state. `initialInput` is always passed through; if the
/// session already exists, zmx's `attach` upserts and the input lands in the
/// running shell (acceptable, matches user expectation that "run script" runs
/// the script).
struct ZmxClient: Sendable {
  /// Bundled zmx executable URL when the budget probe passed, otherwise nil.
  /// Use for the wrap-vs-bypass decision on NEW surfaces.
  var executableURL: @Sendable () -> URL?
  /// True whenever the zmx binary is bundled, independent of the probe outcome.
  /// Use for kill paths against sessions persisted from earlier launches: probe
  /// bypass only means "don't wrap a new session", not "don't kill an old one".
  var isBundled: @Sendable () -> Bool
  /// Tear down a session. No-op on missing. Bounded by a 5-second timeout so a
  /// stuck daemon can't hold the close path indefinitely.
  var killSession: @Sendable (_ sessionID: String) async -> Void
  /// Best-effort kill of a host-side zmx session over SSH. No-op when the host
  /// lacks zmx. Bounded so an unreachable host can't hold the close path; an
  /// unreachable host leaks the session (no host-side reaper yet).
  var killRemoteSession: @Sendable (_ host: RemoteHost, _ sessionID: String) async -> Void
  /// Returns each live Supacode session with its attached-client count, or nil
  /// when the probe failed/timed out. nil means UNKNOWN (never reap); `[]` means
  /// a successful empty listing. A `clients` of nil marks a session whose count
  /// is unknown (err/status line), which the reaper must also spare.
  var listSessionsWithClients: @Sendable () async -> [ZmxSessionListParser.Entry]?
}

/// Cached probe result so we log the bypass reason exactly once per process
/// rather than every call into `resolveExecutable`.
nonisolated private enum ProbeOutcome: Equatable, Sendable {
  case allow
  case bypass
}

extension ZmxClient {
  /// 5-second cap on any `zmx` subprocess so a stuck daemon never blocks the
  /// app's close / quit paths. Empirically every `zmx` call we issue (ls / kill)
  /// completes in <100ms; if it doesn't, something is wrong and we'd rather log
  /// + continue than hang.
  nonisolated static let subprocessTimeout: Duration = .seconds(5)

  /// Cap on a host-side kill over SSH: `ConnectTimeout=10` plus handshake
  /// headroom, so a dead host fails fast without wedging teardown.
  nonisolated static let remoteSubprocessTimeout: Duration = .seconds(15)

  nonisolated static let live: ZmxClient = {
    // Probe once per process. If the effective socket-dir is so long that
    // `<dir>/<session-name>` would exceed macOS' `sun_path` limit, the bundled
    // zmx is unusable; bypass wrapping rather than hand Ghostty a command that
    // dies silently in `zmx attach`. Custom `ZMX_DIR` (corporate managed Macs,
    // sandbox containers with deep paths) is the primary trigger.
    let probed = LockIsolated<ProbeOutcome?>(nil)
    // Cached once: invariant for the process lifetime, hot on close.
    let cachedBundledURL: URL? = Bundle.main.url(
      forResource: "zmx",
      withExtension: nil,
      subdirectory: "zmx"
    )

    @Sendable func resolveExecutable() -> URL? {
      guard let url = cachedBundledURL else { return nil }
      let outcome = probed.withValue { current -> ProbeOutcome in
        if let existing = current { return existing }
        let computed: ProbeOutcome
        if let reason = ZmxSocketBudget.probe() {
          zmxLogger.warning("Bypassing zmx wrapping: \(reason)")
          computed = .bypass
        } else {
          computed = .allow
        }
        current = computed
        return computed
      }
      return outcome == .allow ? url : nil
    }

    @Sendable func bundledExecutable() -> URL? {
      cachedBundledURL
    }

    /// Runs a bounded subprocess and returns captured stdout on success, or nil
    /// on any failure path (spawn error, timeout, non-zero exit). When
    /// `captureStdout` is false the stdout pipe is replaced with `/dev/null`
    /// so fire-and-forget callers can't deadlock the child on a full buffer.
    @Sendable func runProcess(
      invocation: (executableURL: URL, arguments: [String]),
      environment: [String: String]?,
      timeout: Duration,
      commandLabel: String,
      captureStdout: Bool
    ) async -> String? {
      let process = Process()
      process.executableURL = invocation.executableURL
      process.arguments = invocation.arguments
      if let environment {
        process.environment = environment
      }
      // macOS pipe buffer is ~64KB; a child that emits more without us draining
      // would deadlock on write while we wait for `terminationHandler`. Drain
      // captured stdout continuously, or redirect to `/dev/null` for callers
      // that don't need the output.
      let stdoutBuffer = LockIsolated(Data())
      if captureStdout {
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
          let chunk = handle.availableData
          if chunk.isEmpty {
            handle.readabilityHandler = nil
            return
          }
          stdoutBuffer.withValue { $0.append(chunk) }
        }
      } else {
        process.standardOutput = FileHandle.nullDevice
      }
      let stderrPipe = Pipe()
      process.standardError = stderrPipe
      let stderrBuffer = LockIsolated(Data())
      stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty {
          handle.readabilityHandler = nil
          return
        }
        stderrBuffer.withValue { $0.append(chunk) }
      }
      // `terminationHandler` is the cancellation-safe exit signal: outer
      // task cancellation tears down the awaiter without leaking a sync
      // `readDataToEndOfFile` that would pin the executor. The handler is
      // wired BEFORE `run()` so the signal is never missed.
      let exitStream = AsyncStream<Int32> { continuation in
        process.terminationHandler = { proc in
          continuation.yield(proc.terminationStatus)
          continuation.finish()
        }
      }
      do {
        try process.run()
      } catch {
        zmxLogger.warning("\(commandLabel) failed: \(error)")
        return nil
      }
      let exitStatus = await withTaskGroup(of: Int32?.self) { group -> Int32? in
        group.addTask {
          for await status in exitStream { return status }
          return nil
        }
        group.addTask {
          try? await Task.sleep(for: timeout)
          return nil
        }
        defer { group.cancelAll() }
        return await group.next() ?? nil
      }
      guard let exitStatus else {
        if process.isRunning { process.terminate() }
        // Wait for the kernel to actually reap the process before returning so
        // we don't leak zombies for the caller's lifetime. Bounded so a wedged
        // SIGTERM target can't extend the close path further.
        _ = await withTaskGroup(of: Void.self) { group in
          group.addTask {
            for await _ in exitStream {}
          }
          group.addTask {
            try? await Task.sleep(for: .seconds(1))
          }
          defer { group.cancelAll() }
          await group.next()
        }
        if Task.isCancelled {
          // Expected on the budgeted quit sweep; the child was SIGTERMed and
          // given no reap window, so `isRunning` would be misleading here.
          zmxLogger.info("\(commandLabel) cancelled; child terminated")
        } else if process.isRunning {
          zmxLogger.warning("\(commandLabel) timed out after \(timeout); child survived SIGTERM and was not reaped")
        } else {
          zmxLogger.warning("\(commandLabel) timed out after \(timeout)")
        }
        return nil
      }
      if exitStatus != 0 {
        let stderr = stderrBuffer.withValue { String(data: $0, encoding: .utf8) ?? "" }
        zmxLogger.warning("\(commandLabel) exit=\(exitStatus) stderr=\(stderr)")
        return nil
      }
      guard captureStdout else { return nil }
      return stdoutBuffer.withValue { String(data: $0, encoding: .utf8) ?? "" }
    }

    /// Runs a bundled-zmx subcommand; nil when unbundled or on any failure.
    @Sendable func runZmx(_ arguments: [String], captureStdout: Bool = false) async -> String? {
      // Uses `bundledExecutable`, not the budget-gated `resolveExecutable`, so
      // kill paths still tear down sessions from a previous under-budget launch
      // even when this launch's `ZMX_DIR` is over budget.
      guard let executable = bundledExecutable() else { return nil }
      // Pin `ZMX_DIR` so the subprocess resolves the same socket dir as the
      // wrapped shell. Defense-in-depth against future env divergence even
      // after the separator fix in `socketDir`.
      var env = ProcessInfo.processInfo.environment
      env["ZMX_DIR"] = ZmxSocketBudget.socketDir(env: env)
      return await runProcess(
        invocation: (executableURL: executable, arguments: arguments),
        environment: env,
        timeout: subprocessTimeout,
        commandLabel: "zmx " + arguments.joined(separator: " "),
        captureStdout: captureStdout
      )
    }

    return ZmxClient(
      executableURL: resolveExecutable,
      isBundled: { bundledExecutable() != nil },
      killSession: { sessionID in
        _ = await runZmx(["kill", sessionID])
      },
      killRemoteSession: { host, sessionID in
        _ = await runProcess(
          invocation: ZmxAttach.remoteKillInvocation(host: host, sessionID: sessionID),
          environment: nil,
          timeout: remoteSubprocessTimeout,
          commandLabel: "ssh \(host.sshDestination) zmx kill \(sessionID)",
          captureStdout: false
        )
      },
      listSessionsWithClients: {
        // nil from runZmx is the UNKNOWN signal (spawn error / timeout / non-zero
        // exit); preserve it so the reaper never kills against a failed probe.
        guard let stdout = await runZmx(["ls"], captureStdout: true) else { return nil }
        return ZmxSessionListParser.parse(stdout)
      }
    )
  }()

  nonisolated static let noop = ZmxClient(
    executableURL: { nil },
    isBundled: { false },
    killSession: { _ in },
    killRemoteSession: { _, _ in },
    listSessionsWithClients: { [] }
  )
}

extension ZmxClient: DependencyKey {
  nonisolated static let liveValue: ZmxClient = .live
  nonisolated static let testValue: ZmxClient = .noop
}

extension DependencyValues {
  nonisolated var zmxClient: ZmxClient {
    get { self[ZmxClient.self] }
    set { self[ZmxClient.self] = newValue }
  }
}

/// Pure parser for zmx's full (`ls`, non-`--short`) tab-delimited listing.
/// Each line is `[→ |  ]name=<name>\tk=v\t...`; a healthy session carries
/// `clients=<n>`, an unreachable one carries `err=`/`status=` (no count).
nonisolated enum ZmxSessionListParser {
  struct Entry: Equatable, Sendable {
    var name: String
    /// nil when the count is unknown (err/status line); the reaper spares these.
    var clients: Int?
  }

  static func parse(_ stdout: String) -> [Entry] {
    stdout
      .split(whereSeparator: \.isNewline)
      .compactMap { line -> Entry? in
        // Strip the current-session arrow / leading indent before tokenizing.
        var trimmed = Substring(line)
        if trimmed.hasPrefix("→ ") {
          trimmed = trimmed.dropFirst(2)
        }
        // Non-current sessions are indented with a literal leading space run.
        while trimmed.first?.isWhitespace == true {
          trimmed = trimmed.dropFirst()
        }
        let fields = trimmed.split(separator: "\t")
        var values: [Substring: Substring] = [:]
        for field in fields {
          guard let separator = field.firstIndex(of: "=") else { continue }
          let key = field[field.startIndex..<separator]
          let value = field[field.index(after: separator)...]
          values[key] = value
        }
        guard let name = values["name"], name.hasPrefix(ZmxSessionID.prefix) else { return nil }
        // Absent `clients=` (err/status line) maps to nil = unknown, not zero.
        let clients = values["clients"].flatMap { Int($0) }
        return Entry(name: String(name), clients: clients)
      }
  }
}

/// Pure session-ID helpers. zmx's macOS socket-path budget is ~46 chars (sun_path
/// is 104, default socket dir is ~58); `supa-<UUID>` lands at 41, leaving
/// headroom for a longer custom `ZMX_DIR`.
nonisolated enum ZmxSessionID {
  static let prefix = "supa-"

  static func make(surfaceID: UUID) -> String {
    prefix + surfaceID.uuidString.lowercased()
  }
}

nonisolated enum ZmxSocketBudget {
  /// macOS `sockaddr_un.sun_path` limit, minus a small safety margin.
  static let sunPathLimit = 104
  static let safetyMargin = 2

  /// `"supa-" + 36-char UUID` is always 41 bytes; hardcoded so `probe` doesn't
  /// allocate a fresh UUID per call just to count the resulting string.
  static let sessionNameByteCount = ZmxSessionID.prefix.utf8.count + 36

  /// Resolved zmx socket directory: `ZMX_DIR`, then `XDG_RUNTIME_DIR`/zmx, then
  /// `TMPDIR`/zmx-<uid>, then `/tmp/zmx-<uid>`. Mirrors zmx's own resolver
  /// (`ThirdParty/zmx/src/main.zig:504-517`) including its trailing-slash trim,
  /// so kill and the wrapped shell can't end up on different directories when
  /// the env variable lacks a trailing `/`. The `env` parameter is injectable
  /// so tests can drive inputs deterministically without depending on process
  /// state.
  static func socketDir(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    if let custom = env["ZMX_DIR"], !custom.isEmpty {
      return custom
    }
    let uid = getuid()
    if let xdg = env["XDG_RUNTIME_DIR"], !xdg.isEmpty {
      return "\(trimTrailingSlash(xdg))/zmx"
    }
    if let tmp = env["TMPDIR"], !tmp.isEmpty {
      return "\(trimTrailingSlash(tmp))/zmx-\(uid)"
    }
    return "/tmp/zmx-\(uid)"
  }

  private static func trimTrailingSlash(_ value: String) -> String {
    var trimmed = Substring(value)
    while trimmed.hasSuffix("/") {
      trimmed = trimmed.dropLast()
    }
    return String(trimmed)
  }

  /// Returns a non-nil reason string when the bundled `supa-<UUID>` session name
  /// would not fit under `sockaddr_un.sun_path` for the current socket dir.
  /// Nil means safe to use.
  static func probe(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    let dir = socketDir(env: env)
    let totalLen = dir.utf8.count + 1 + sessionNameByteCount
    let budget = sunPathLimit - safetyMargin
    if totalLen > budget {
      return "socket path \(totalLen)B exceeds budget \(budget)B (dir=\(dir))"
    }
    return nil
  }
}

nonisolated enum ZmxAttach {
  /// Ghostty wraps `config.command` as `/bin/sh -c "<value>"` on macOS (verified
  /// against `ThirdParty/ghostty/src/termio/Exec.zig` + `config/command.zig`), so
  /// POSIX single-quote escaping is correct. Don't change this without
  /// re-verifying upstream Ghostty's command-handling path.
  static func buildCommand(executablePath: String, sessionID: String, userCommand: String?) -> String {
    let quotedExe = shellQuote(executablePath)
    let attach = "\(quotedExe) attach \(sessionID)"
    guard let command = userCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
      return attach
    }
    return "\(attach) /bin/sh -c \(shellQuote(command))"
  }

  /// Argv that launches an interactive surface under zmx, passed to Ghostty as a
  /// `command-wrapper` (prepended to the resolved shell argv). Each element is a
  /// separate arg, so no shell quoting is needed even when the path has spaces.
  static func buildWrapperArgv(executablePath: String, sessionID: String) -> [String] {
    [executablePath, "attach", sessionID]
  }

  /// Resolves how a surface launches under zmx, given the budget-gated executable
  /// path (nil when zmx is unbundled or over budget). Interactive surfaces
  /// (`command == nil`) keep a nil command and get an argv `command-wrapper`, so
  /// Ghostty resolves + integrates the real shell and zmx wraps the result.
  /// Explicit commands (scripts) get a `/bin/sh -c` wrapped command string and no
  /// wrapper. A nil `executablePath` falls through to the raw command with no zmx.
  static func resolveLaunch(
    executablePath: String?,
    sessionID: String,
    command: String?
  ) -> (command: String?, commandWrapper: [String]) {
    // A blank command is "no command" (interactive); normalize so an empty
    // string can't slip into the script path and launch a bare shell uninteg.
    let command = command.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    guard let executablePath else { return (command, []) }
    if command == nil {
      return (nil, buildWrapperArgv(executablePath: executablePath, sessionID: sessionID))
    }
    return (buildCommand(executablePath: executablePath, sessionID: sessionID, userCommand: command), [])
  }

  static func shellQuote(_ value: String) -> String {
    let escaped = value.replacing("'", with: "'\\''")
    return "'\(escaped)'"
  }

  /// Everything the remote side needs to build a surface's connect and
  /// reconnect scripts. `userCommand` is the explicit command (nil for an
  /// interactive surface); `defaultCommand` is the cd-into-worktree login
  /// shell (nil for a root path). Reconnects never re-run `userCommand`: a
  /// one-shot command whose host session ended while disconnected must not
  /// repeat its side effects.
  struct RemoteSurfaceLaunch {
    var host: RemoteHost
    var surfaceID: UUID
    var userCommand: String?
    var defaultCommand: String?
    var hostPersistenceEnabled: Bool

    var sessionID: String { ZmxSessionID.make(surfaceID: surfaceID) }

    var export: String {
      "export SUPACODE_SURFACE_ID=\(ZmxAttach.shellQuote(surfaceID.uuidString)); "
    }

    /// Whitespace-only commands count as absent.
    var normalizedUserCommand: String? {
      Self.normalized(userCommand)
    }

    /// First-connect command: `userCommand`, else the worktree default, else a
    /// bare login shell.
    var connectCommand: String {
      normalizedUserCommand ?? reconnectFallbackCommand
    }

    /// Reconnect fallback (no host session to reattach): the worktree default
    /// shell, never the user command.
    var reconnectFallbackCommand: String {
      Self.normalized(defaultCommand) ?? "exec \"$SHELL\" -l"
    }

    private static func normalized(_ command: String?) -> String? {
      let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed?.isEmpty == false ? trimmed : nil
    }
  }

  /// Remote surface command: a *local* zmx session whose child is a reconnect
  /// loop around the SSH connection. The first attempt creates-or-attaches the
  /// host-side session (see `remoteConnectScript`); retries after a 255 only
  /// reattach an existing one (see `remoteReconnectScript`), restoring the
  /// screen state. `localZmxExecutablePath` is the budget-gated bundle path
  /// (nil when zmx is unbundled or over budget), in which case the surface is
  /// the bare loop with no quit persistence, but reconnect still works. The
  /// reconnect loop (ssh lines included) is single-quoted by `buildCommand`
  /// for the local zmx-wrapping `/bin/sh -c`; the ssh lines' inner quoting
  /// survives that outer level.
  static func buildRemoteCommand(
    _ launch: RemoteSurfaceLaunch,
    localZmxExecutablePath: String?
  ) -> String {
    let connectLine = SSHCommand.commandLine(
      host: launch.host,
      remoteCommand: posixShellWrapped(remoteConnectScript(launch))
    )
    let reconnectLine = SSHCommand.commandLine(
      host: launch.host,
      remoteCommand: posixShellWrapped(remoteReconnectScript(launch))
    )
    let loop = SSHReconnectLoop.script(connect: connectLine, reconnect: reconnectLine)
    guard let localZmxExecutablePath else { return loop }
    // The local and host-side sessions share the `supa-<surfaceID>` name.
    return buildCommand(
      executablePath: localZmxExecutablePath,
      sessionID: launch.sessionID,
      userCommand: loop
    )
  }

  /// Re-quotes a remote script behind `exec /bin/sh -c`, so the login shell
  /// (which may be fish or csh) only has to parse that one portable line; the
  /// POSIX `if/fi` script runs in /bin/sh with the login shell's exported
  /// PATH already in place.
  static func posixShellWrapped(_ script: String) -> String {
    "exec /bin/sh -c " + shellQuote(script)
  }

  /// Runs a command under a fresh login shell. Commands must never execute in
  /// the `posixShellWrapped` /bin/sh layer directly: on dash-as-/bin/sh hosts
  /// that would break bash/zsh-isms that worked before the wrapper existed.
  static func loginShellRun(_ command: String) -> String {
    "exec \"$SHELL\" -l -c " + shellQuote(command)
  }

  /// The first-connect script: exports the surface id (so the agent hook's
  /// in-band presence OSC is gated to a Supacode surface, see
  /// `AgentPresenceOSC.emitShell`), then runs the connect command. When
  /// `hostPersistenceEnabled` and the host has zmx on its login-shell PATH,
  /// the command runs inside a host-side `zmx attach supa-<surfaceID>`
  /// session (a login shell via `"$SHELL" -l`, so the session shell matches
  /// the non-zmx branch on dash-as-/bin/sh hosts). The env export precedes
  /// the attach, so the session inherits it on create. A failed attach falls
  /// through to a plain run with a visible notice instead of an instant,
  /// unreadable close. The awaiting-input signal rides the terminal stream
  /// (OSC 3008), not a socket, so no reverse forward is needed.
  static func remoteConnectScript(_ launch: RemoteSurfaceLaunch) -> String {
    let command = launch.connectCommand
    guard launch.hostPersistenceEnabled else {
      return launch.export + betaBanner + loginShellRun(command)
    }
    // Always the `-c` form: the interactive default carries the cd into the
    // worktree, so the created session must run it too, via a login shell so
    // dash-as-/bin/sh hosts keep bash/zsh semantics. The banners ride INSIDE
    // the session command: printed outside it they would be swallowed by
    // zmx's screen takeover, inside it they land in the session's screen
    // state and so also survive reattach restores.
    let sessionCommand = "\"$SHELL\" -l -c " + shellQuote(betaBanner + persistentBanner + command)
    // Newline separators keep a command with a trailing `;` from breaking
    // the `fi`; the trailing fallback line serves only the no-zmx branch.
    // The failed-attach fallthrough execs its own fresh default shell, never
    // `command`: attach can fail AFTER the session started running it, and a
    // second concurrent copy of a one-shot command must never spawn.
    return launch.export
      + "if command -v zmx >/dev/null 2>&1; then "
      + "zmx attach \(launch.sessionID) \(sessionCommand)\n"
      + "supa_rc=$?\n"
      + "[ \"$supa_rc\" -eq 0 ] && exit 0\n"
      + #"printf '\033[1;31m── zmx attach exited with status %s. "#
      + #"Continuing without host persistence. ──\033[0m\r\n' "$supa_rc"; "#
      + "\n"
      + loginShellRun(launch.reconnectFallbackCommand) + "\n"
      + "else "
      + betaBanner + zmxInstallHintBanner
      + "\n"
      + "fi\n"
      + loginShellRun(command)
  }

  /// The reconnect script, used by the loop after a dropped connection:
  /// reattach the host session if it still exists, exit 0 (closing the pane
  /// like a normal remote exit, with a notice) if it ended while
  /// disconnected, and never re-run the user command. Without host zmx (or
  /// with persistence off) it drops into the worktree default shell. If the
  /// session dies between the list check and the attach, the upsert recreates
  /// a blank shell session; accepted (the window is milliseconds).
  static func remoteReconnectScript(_ launch: RemoteSurfaceLaunch) -> String {
    guard launch.hostPersistenceEnabled else {
      return launch.export + reconnectShellNotice + loginShellRun(launch.reconnectFallbackCommand)
    }
    return launch.export
      + "if command -v zmx >/dev/null 2>&1; then "
      + "if zmx list --short 2>/dev/null | grep -q '\(launch.sessionID)$'; then "
      + "exec zmx attach \(launch.sessionID)\n"
      + "fi\n"
      + sessionEndedNotice + "exit 0\n"
      + "fi\n"
      + reconnectShellNotice
      + loginShellRun(launch.reconnectFallbackCommand)
  }

  /// Best-effort teardown of the host-side session created by
  /// `remoteConnectScript`. Rides the login shell (brew PATH) and the shared
  /// control socket; the `command -v` guard keeps a host without zmx from
  /// logging a spurious 127 warning on every close (a host whose zmx was
  /// uninstalled mid-session leaks silently, joining the documented leak set).
  static func remoteKillInvocation(
    host: RemoteHost,
    sessionID: String
  ) -> (executableURL: URL, arguments: [String]) {
    SSHCommand.invocation(
      host: host,
      executable: "/bin/sh",
      // `|| exit 0`, not `&&`: a host without zmx must exit 0 (true no-op),
      // or every close logs a spurious exit-1 warning. The trailing list
      // re-check surfaces a kill that silently failed (`zmx kill` exits 0
      // even when the session survives): a leftover session exits 1, which
      // `runProcess` logs.
      arguments: [
        "-c",
        "command -v zmx >/dev/null 2>&1 || exit 0; zmx kill \(sessionID); "
          + "! zmx list --short 2>/dev/null | grep -q '\(sessionID)$'",
      ],
      workingDirectory: nil,
      extraOptions: SSHCommand.backgroundProbeOptions
    )
  }

  /// OSC 8 hyperlink to the zmx site (terminals without OSC 8 support just
  /// render the plain "zmx" text).
  static let zmxHyperlink = #"\033]8;;https://zmx.sh\033\\zmx\033]8;;\033\\"#

  /// Dim banner with a bold "Beta", printed at the top of a remote surface on
  /// first connect. Remote surfaces are in beta and some local-only features
  /// (Unix-socket agent hooks, worktree HEAD watching) are unavailable, so
  /// the user gets an up-front heads-up.
  static let betaBanner =
    #"printf '\033[2m── Remote Supacode surfaces are in \033[0m\033[1mBeta\033[0m\033[2m "#
    + #"and may have reduced functionality. ──\033[0m\r\n'; "#

  /// Dim banner for a host-persisted surface, with a bold "persisted" and the
  /// survival promise in green, plus a footnote on how to actually end it
  /// (persistence inverts the close-kills-it default, so the exit paths are
  /// not guessable). No zmx mention: the tool only matters when it is
  /// missing. Runs inside the session command, never before `zmx attach`
  /// (the attach redraw would swallow it).
  static let persistentBanner =
    #"printf '\033[2m── Remote session \033[0m\033[1mpersisted\033[0m\033[2m on this host.\033[0m "#
    + #"\033[32mIt \033[1msurvives\033[0m\033[32m disconnects.\033[0m\033[2m ──\033[0m\r\n"#
    + #"\033[2m   Type exit or close this surface to end it on the host.\033[0m\r\n'; "#

  /// Dim hint with install suggestions, appended to the beta banner when the
  /// host has no zmx. Same emphasis as `persistentBanner`: bold key phrase,
  /// green benefit clause, dim everything else. "New sessions", not
  /// "sessions": installing zmx cannot retroactively persist this one.
  static let zmxInstallHintBanner =
    #"printf '\033[2m── \033[0m\033[1mInstall "# + zmxHyperlink
    + #"\033[0m\033[2m on this host to \033[0m\033[32mkeep \033[4mnew\033[24m sessions \033[1malive\033[0m\033[32m "#
    + #"across disconnects.\033[0m\033[2m ──\033[0m\r\n"#
    + #"\033[2m   macOS: brew install neurosnap/tap/zmx\033[0m\r\n"#
    + #"\033[2m   Linux: https://zmx.sh (prebuilt binaries and packages)\033[0m\r\n'; "#

  /// Bold yellow notice printed when a reconnect lands in a fresh shell
  /// because there is no host session to resume.
  static let reconnectShellNotice =
    #"printf '\033[1;33m── Reconnected without a persistent session; starting a fresh shell. ──\033[0m\r\n'; "#

  /// Dim notice printed right before the pane closes because the host
  /// session ended while disconnected; without it the tab just vanishes.
  static let sessionEndedNotice =
    #"printf '\033[2m── Remote session ended while disconnected. ──\033[0m\r\n'; "#
}

/// Local `/bin/sh` retry loop around two ssh command lines: `connect` runs
/// once (create-or-attach), `reconnect` runs on every retry (attach-only).
/// ssh reserves exit 255 for its own connection errors, so 255 retries (with
/// capped backoff, forever, so an overnight sleep still resumes) and every
/// other exit passes through, closing the surface like a local shell exit.
/// 255 also covers permanent ssh failures (auth, host key, DNS), which retry
/// too; the banner names the exit code and ssh's own error text stays
/// visible above it. Ctrl-C during the wait is the escape hatch (`trap`
/// makes it deterministic; while ssh is live the tty is raw and Ctrl-C goes
/// to the remote).
nonisolated enum SSHReconnectLoop {
  static let maxDelaySeconds = 15

  static func script(connect: String, reconnect: String) -> String {
    let passExitUnless255 = "; supa_rc=$?; [ \"$supa_rc\" -ne 255 ] && exit \"$supa_rc\""
    return "trap 'exit 130' INT; "
      + connect + passExitUnless255 + "; "
      + "supa_delay=1; while :; do "
      + #"printf '\033[1;33m── Connection failed (ssh exit 255). Retrying in %ss. "#
      + #"Press Ctrl-C to stop. ──\033[0m\r\n' "$supa_delay"; "#
      + "sleep \"$supa_delay\"; supa_delay=$((supa_delay * 2)); "
      + "[ \"$supa_delay\" -gt \(maxDelaySeconds) ] && supa_delay=\(maxDelaySeconds); "
      + reconnect + passExitUnless255 + "; done"
  }
}
