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

    /// Runs a zmx subcommand and returns captured stdout on success, or nil on
    /// any failure path (unbundled, spawn error, timeout, non-zero exit). When
    /// `captureStdout` is false the stdout pipe is replaced with `/dev/null`
    /// so fire-and-forget callers can't deadlock the child on a full buffer.
    @Sendable func runZmx(_ arguments: [String], captureStdout: Bool = false) async -> String? {
      // Uses `bundledExecutable`, not the budget-gated `resolveExecutable`, so
      // kill paths still tear down sessions from a previous under-budget launch
      // even when this launch's `ZMX_DIR` is over budget.
      guard let executable = bundledExecutable() else { return nil }
      let command = "zmx " + arguments.joined(separator: " ")
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      // Pin `ZMX_DIR` so the subprocess resolves the same socket dir as the
      // wrapped shell. Defense-in-depth against future env divergence even
      // after the separator fix in `socketDir`.
      var env = ProcessInfo.processInfo.environment
      env["ZMX_DIR"] = ZmxSocketBudget.socketDir(env: env)
      process.environment = env
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
        zmxLogger.warning("\(command) failed: \(error)")
        return nil
      }
      let exitStatus = await withTaskGroup(of: Int32?.self) { group -> Int32? in
        group.addTask {
          for await status in exitStream { return status }
          return nil
        }
        group.addTask {
          try? await Task.sleep(for: subprocessTimeout)
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
        zmxLogger.warning("\(command) timed out after \(subprocessTimeout)")
        return nil
      }
      if exitStatus != 0 {
        let stderr = stderrBuffer.withValue { String(data: $0, encoding: .utf8) ?? "" }
        zmxLogger.warning("\(command) exit=\(exitStatus) stderr=\(stderr)")
        return nil
      }
      guard captureStdout else { return nil }
      return stdoutBuffer.withValue { String(data: $0, encoding: .utf8) ?? "" }
    }

    return ZmxClient(
      executableURL: resolveExecutable,
      isBundled: { bundledExecutable() != nil },
      killSession: { sessionID in
        _ = await runZmx(["kill", sessionID])
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

  /// Remote surface command: a *local* zmx session whose child process is the
  /// SSH connection to `host`. Session persistence (detach / reattach) lives on
  /// the client; the remote just runs a plain login shell, so nothing has to be
  /// installed on the host. `localZmxExecutablePath` is the budget-gated bundle
  /// path (nil when zmx is unbundled or over budget), in which case the surface
  /// is the bare ssh line with no persistence. The ssh line is single-quoted by
  /// `buildCommand` for the local zmx-wrapping `/bin/sh -c`; its own inner
  /// quoting (from `SSHCommand.commandLine`) survives that outer level.
  static func buildRemoteCommand(
    host: RemoteHost,
    localZmxExecutablePath: String?,
    sessionID: String,
    userCommand: String?,
    surfaceID: UUID
  ) -> String {
    let sshLine = SSHCommand.commandLine(
      host: host,
      remoteCommand: remoteShellCommand(userCommand: userCommand, surfaceID: surfaceID)
    )
    guard let localZmxExecutablePath else { return sshLine }
    return buildCommand(executablePath: localZmxExecutablePath, sessionID: sessionID, userCommand: sshLine)
  }

  /// The command the *remote* shell runs over SSH: exports the surface id (so the
  /// agent hook's in-band presence OSC is gated to a Supacode surface, see
  /// `AgentPresenceOSC.emitShell`), prints the beta banner once at connection,
  /// then runs the user command, or a login shell when there is none. No zmx on
  /// the remote: persistence is the local zmx wrapping the whole ssh line. The
  /// awaiting-input signal rides the terminal stream (OSC 3008), not a socket, so
  /// no reverse forward / remote `SUPACODE_SOCKET_PATH` is needed (the pid suffix
  /// is dropped over SSH).
  static func remoteShellCommand(
    userCommand: String?,
    surfaceID: UUID
  ) -> String {
    let prelude = "export SUPACODE_SURFACE_ID=\(shellQuote(surfaceID.uuidString)); " + betaBanner
    guard let command = userCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
      return prelude + "exec \"$SHELL\" -l"
    }
    return prelude + command
  }

  /// Dim banner printed at the top of a remote surface on connection, matching
  /// the blocking-script read-only banner style. Remote surfaces are in beta and
  /// some local-only features (Unix-socket agent hooks, worktree HEAD watching)
  /// are unavailable, so the user gets an up-front heads-up. The session persists
  /// across reattach, so this only prints on the first connect.
  static let betaBanner =
    #"printf '\033[2m── Remote Supacode surfaces are in beta and may have reduced functionality. ──\033[0m\r\n'; "#
}
