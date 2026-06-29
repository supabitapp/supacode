import ComposableArchitecture
import Darwin
import Foundation

/// A streaming login-shell process plus an explicit terminate handle. `events`
/// finishes only after the process has actually exited (including after a
/// `terminate()`), so a consumer that drains to completion can clean up without
/// racing the asynchronous SIGTERM/SIGKILL teardown.
public nonisolated struct StreamingShellProcess: Sendable {
  public let events: AsyncThrowingStream<ShellStreamEvent, Error>
  public let terminate: @Sendable () -> Void

  public init(events: AsyncThrowingStream<ShellStreamEvent, Error>, terminate: @escaping @Sendable () -> Void) {
    self.events = events
    self.terminate = terminate
  }
}

public nonisolated struct ShellClient: Sendable {
  public var run: @Sendable (URL, [String], URL?) async throws -> ShellOutput
  public var runLoginImpl: @Sendable (URL, [String], URL?, Bool) async throws -> ShellOutput
  public var runStream: @Sendable (URL, [String], URL?) -> AsyncThrowingStream<ShellStreamEvent, Error>
  public var runLoginStreamImpl: @Sendable (URL, [String], URL?, Bool) -> AsyncThrowingStream<ShellStreamEvent, Error>
  public var runLoginProcessImpl: @Sendable (URL, [String], URL?, Bool) -> StreamingShellProcess

  public init(
    run: @escaping @Sendable (URL, [String], URL?) async throws -> ShellOutput,
    runLoginImpl: @escaping @Sendable (URL, [String], URL?, Bool) async throws -> ShellOutput,
    runStream: (@Sendable (URL, [String], URL?) -> AsyncThrowingStream<ShellStreamEvent, Error>)? = nil,
    runLoginStreamImpl:
      (@Sendable (URL, [String], URL?, Bool) -> AsyncThrowingStream<ShellStreamEvent, Error>)? = nil,
    runLoginProcessImpl: (@Sendable (URL, [String], URL?, Bool) -> StreamingShellProcess)? = nil
  ) {
    self.run = run
    self.runLoginImpl = runLoginImpl
    self.runStream =
      runStream
      ?? { executableURL, arguments, currentDirectoryURL in
        AsyncThrowingStream { continuation in
          Task {
            do {
              let output = try await run(executableURL, arguments, currentDirectoryURL)
              continuation.yield(.finished(output))
              continuation.finish()
            } catch {
              continuation.finish(throwing: error)
            }
          }
        }
      }
    let resolvedRunLoginStreamImpl =
      runLoginStreamImpl
      ?? { executableURL, arguments, currentDirectoryURL, log in
        AsyncThrowingStream { continuation in
          Task {
            do {
              let output = try await runLoginImpl(executableURL, arguments, currentDirectoryURL, log)
              continuation.yield(.finished(output))
              continuation.finish()
            } catch {
              continuation.finish(throwing: error)
            }
          }
        }
      }
    self.runLoginStreamImpl = resolvedRunLoginStreamImpl
    // Default to the login-stream events with a no-op terminate; only the live
    // process supports real termination. Mocks drive their injected stream.
    self.runLoginProcessImpl =
      runLoginProcessImpl
      ?? { executableURL, arguments, currentDirectoryURL, log in
        StreamingShellProcess(
          events: resolvedRunLoginStreamImpl(executableURL, arguments, currentDirectoryURL, log),
          terminate: {}
        )
      }
  }

  public func runLogin(
    _ executableURL: URL,
    _ arguments: [String],
    _ currentDirectoryURL: URL?,
    log: Bool = true
  ) async throws -> ShellOutput {
    try await runLoginImpl(executableURL, arguments, currentDirectoryURL, log)
  }

  public func runLoginStream(
    _ executableURL: URL,
    _ arguments: [String],
    _ currentDirectoryURL: URL?,
    log: Bool = true
  ) -> AsyncThrowingStream<ShellStreamEvent, Error> {
    runLoginStreamImpl(executableURL, arguments, currentDirectoryURL, log)
  }

  public func runLoginProcess(
    _ executableURL: URL,
    _ arguments: [String],
    _ currentDirectoryURL: URL?,
    log: Bool = true
  ) -> StreamingShellProcess {
    runLoginProcessImpl(executableURL, arguments, currentDirectoryURL, log)
  }
}

extension ShellClient: DependencyKey {
  public nonisolated static let live = ShellClient(
    run: { executableURL, arguments, currentDirectoryURL in
      try await runProcess(
        executableURL: executableURL,
        arguments: arguments,
        currentDirectoryURL: currentDirectoryURL
      )
    },
    runLoginImpl: { executableURL, arguments, currentDirectoryURL, log in
      let (shellURL, execCommand) = ShellClient.loginShellInvocation(
        userShell: URL(fileURLWithPath: defaultShellPath()))
      let shellArguments =
        ["-l", "-c", execCommand, "--", executableURL.path(percentEncoded: false)] + arguments
      if log {
        let cwd = currentDirectoryURL?.path(percentEncoded: false) ?? "nil"
        let cmd = shellArguments.joined(separator: " ")
        shellLogger.debug("runLogin cwd=\(cwd) cmd=\(shellURL.path) \(cmd)")
      }
      let result = try await runProcess(
        executableURL: shellURL,
        arguments: shellArguments,
        currentDirectoryURL: currentDirectoryURL
      )
      return result
    },
    runStream: { executableURL, arguments, currentDirectoryURL in
      runProcessStream(
        executableURL: executableURL,
        arguments: arguments,
        currentDirectoryURL: currentDirectoryURL
      )
    },
    runLoginStreamImpl: { executableURL, arguments, currentDirectoryURL, log in
      runLoginProcessHandle(
        executableURL: executableURL,
        arguments: arguments,
        currentDirectoryURL: currentDirectoryURL,
        log: log
      ).events
    },
    runLoginProcessImpl: { executableURL, arguments, currentDirectoryURL, log in
      runLoginProcessHandle(
        executableURL: executableURL,
        arguments: arguments,
        currentDirectoryURL: currentDirectoryURL,
        log: log
      )
    }
  )

  public static let liveValue = live

  public static let testValue = ShellClient(
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
        continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
        continuation.finish()
      }
    }
  )
}

extension DependencyValues {
  public var shellClient: ShellClient {
    get { self[ShellClient.self] }
    set { self[ShellClient.self] = newValue }
  }
}

private nonisolated let shellLogger = SupaLogger("Shell")

nonisolated private func runProcess(
  executableURL: URL,
  arguments: [String],
  currentDirectoryURL: URL?
) async throws -> ShellOutput {
  let stream = runProcessStream(
    executableURL: executableURL,
    arguments: arguments,
    currentDirectoryURL: currentDirectoryURL
  )
  let command = ([executableURL.path(percentEncoded: false)] + arguments).joined(separator: " ")
  return try await collectOutput(from: stream, command: command)
}

nonisolated private func runProcessStream(
  executableURL: URL,
  arguments: [String],
  currentDirectoryURL: URL?
) -> AsyncThrowingStream<ShellStreamEvent, Error> {
  runProcessHandle(
    executableURL: executableURL,
    arguments: arguments,
    currentDirectoryURL: currentDirectoryURL
  ).events
}

/// Wrap `executableURL` in a login shell and run it as a terminable process. Both
/// runLogin streaming entry points share this so the invocation, argv, and debug
/// log stay identical.
nonisolated private func runLoginProcessHandle(
  executableURL: URL,
  arguments: [String],
  currentDirectoryURL: URL?,
  log: Bool
) -> StreamingShellProcess {
  let (shellURL, execCommand) = ShellClient.loginShellInvocation(
    userShell: URL(fileURLWithPath: defaultShellPath()))
  let shellArguments =
    ["-l", "-c", execCommand, "--", executableURL.path(percentEncoded: false)] + arguments
  if log {
    let cwd = currentDirectoryURL?.path(percentEncoded: false) ?? "nil"
    let cmd = shellArguments.joined(separator: " ")
    shellLogger.debug("runLogin cwd=\(cwd) cmd=\(shellURL.path) \(cmd)")
  }
  return runProcessHandle(
    executableURL: shellURL,
    arguments: shellArguments,
    currentDirectoryURL: currentDirectoryURL
  )
}

/// Shared launch / termination state for a `runProcessHandle` child, guarded by a
/// `LockIsolated` so the launch, an early `terminate()`, and the post-exit reap
/// observe a consistent view of the pid.
private nonisolated struct ProcessSignalState {
  var pid: Int32 = 0
  var terminateRequested = false
  var exited = false
}

/// SIGTERM a child, then SIGKILL after a short grace so a process that ignores
/// SIGTERM (a stalled ssh) can't keep its task hung.
nonisolated private func sendTerminationSignals(to pid: Int32) {
  guard pid > 0 else { return }
  kill(pid, SIGTERM)
  Task.detached {
    try? await Task.sleep(for: .seconds(2))
    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
  }
}

/// Run a process, exposing both its event stream and an explicit `terminate`
/// handle. `events` finishes only after `waitUntilExit()` returns, so a consumer
/// that drains to completion after calling `terminate()` can clean up without
/// racing the SIGTERM/SIGKILL teardown. Consumer-task cancellation still kills
/// the child (so existing stream consumers keep their timeout behavior).
nonisolated private func runProcessHandle(
  executableURL: URL,
  arguments: [String],
  currentDirectoryURL: URL?
) -> StreamingShellProcess {
  // The pid is only known after `run()`, so a `terminate()` that arrives first
  // sets a flag the launch honors. The `exited` flag suppresses signals once the
  // process is reaped so we don't SIGTERM/SIGKILL a pid the OS may have reused.
  let signalState = LockIsolated(ProcessSignalState())
  let terminate: @Sendable () -> Void = {
    let pid = signalState.withValue { state -> Int32 in
      guard !state.exited else { return 0 }
      state.terminateRequested = true
      return state.pid
    }
    sendTerminationSignals(to: pid)
  }
  let events = AsyncThrowingStream<ShellStreamEvent, Error> { continuation in
    Task.detached {
      let outputAccumulator = ShellOutputAccumulator()
      let process = Process()
      process.executableURL = executableURL
      process.arguments = arguments
      process.currentDirectoryURL = currentDirectoryURL
      let outputPipe = Pipe()
      let errorPipe = Pipe()
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = outputPipe
      process.standardError = errorPipe
      let outputHandle = outputPipe.fileHandleForReading
      let errorHandle = errorPipe.fileHandleForReading
      let command = ([executableURL.path(percentEncoded: false)] + arguments).joined(separator: " ")
      do {
        try process.run()
        // Terminate the child only when the consuming task is cancelled (e.g. a
        // remote load probe timing out); on normal completion the process already
        // exited, so signalling its pid would risk a reused pid.
        let pid = process.processIdentifier
        let terminateRaced = signalState.withValue { state -> Bool in
          state.pid = pid
          return state.terminateRequested
        }
        if terminateRaced { sendTerminationSignals(to: pid) }
        continuation.onTermination = { @Sendable termination in
          guard case .cancelled = termination else { return }
          // Skip the signal once the process is reaped so a cancel that races a
          // natural exit never targets a reused pid.
          sendTerminationSignals(to: signalState.withValue { $0.exited ? 0 : $0.pid })
        }
        let stdoutTask = Task.detached {
          for await line in lineStream(from: outputHandle) {
            await outputAccumulator.append(line, source: .stdout)
            continuation.yield(
              .line(
                ShellStreamLine(
                  source: .stdout,
                  text: line
                )
              )
            )
          }
        }
        let stderrTask = Task.detached {
          for await line in lineStream(from: errorHandle) {
            await outputAccumulator.append(line, source: .stderr)
            continuation.yield(
              .line(
                ShellStreamLine(
                  source: .stderr,
                  text: line
                )
              )
            )
          }
        }
        process.waitUntilExit()
        // The pid is reaped; stop any later terminate() from signalling it.
        signalState.withValue { $0.exited = true }
        await stdoutTask.value
        await stderrTask.value
        let output = await outputAccumulator.output(exitCode: process.terminationStatus)
        if process.terminationStatus != 0 {
          continuation.finish(
            throwing: ShellClientError(
              command: command,
              stdout: output.stdout,
              stderr: output.stderr,
              exitCode: output.exitCode
            )
          )
          return
        }
        continuation.yield(.finished(output))
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
  }
  return StreamingShellProcess(events: events, terminate: terminate)
}

nonisolated private func collectOutput(
  from stream: AsyncThrowingStream<ShellStreamEvent, Error>,
  command: String
) async throws -> ShellOutput {
  var finalOutput: ShellOutput?
  for try await event in stream {
    if case .finished(let output) = event {
      finalOutput = output
    }
  }
  guard let finalOutput else {
    throw ShellClientError(command: command, stdout: "", stderr: "", exitCode: -1)
  }
  return finalOutput
}

extension ShellClient {
  /// Builds the `(shell, -c command)` pair for a one-shot login-shell command.
  /// We only drive shells we have a correct rc snippet for — zsh, bash, fish.
  /// Anything else (nushell, sh/dash/ksh, pwsh, …) falls back to /bin/zsh, which
  /// can actually parse the snippet, so the command runs instead of failing
  /// (issue #100). The interactive terminal still uses the user's real shell.
  nonisolated static func loginShellInvocation(userShell: URL) -> (shell: URL, command: String) {
    let drivable: Set<String> = ["zsh", "bash", "fish"]
    let shell =
      drivable.contains(userShell.lastPathComponent)
      ? userShell : URL(fileURLWithPath: "/bin/zsh")
    let command: String
    switch shell.lastPathComponent {
    case "fish":
      command = "test -f ~/.config/fish/config.fish; and source ~/.config/fish/config.fish >/dev/null 2>&1; exec $argv"
    case "bash":
      command = posixLoginCommand(rcFile: "~/.bashrc")
    default:
      command = posixLoginCommand(rcFile: "~/.zshrc")
    }
    return (shell, command)
  }

  /// Builds the zsh/bash one-shot command: capture the positional parameters, clear them, then source
  /// the rc file and exec from the saved array. Sourcing shares `$@` with the caller, so an rc that
  /// resets the positionals (e.g. `set --`) would otherwise wipe the command before `exec` (#441).
  /// Clearing `$@` with `set --` before sourcing also keeps the target command out of the rc's view:
  /// a dual-mode script dispatching on `$1` (e.g. `fzf-git.sh`) would otherwise see the probe's
  /// arguments, hit its own `exit`, and kill the probe shell before `exec` ran (#477). The exec reads
  /// from the saved array, so clearing the live positionals is safe.
  nonisolated private static func posixLoginCommand(rcFile: String) -> String {
    let capture = "__supacode_login_argv=(\"$@\")"
    let clear = "set --"
    let source = "[ -f \(rcFile) ] && . \(rcFile) >/dev/null 2>&1"
    return "\(capture); \(clear); \(source); exec \"${__supacode_login_argv[@]}\""
  }
}

public nonisolated func defaultShellPath() -> String {
  if let env = ProcessInfo.processInfo.environment["SHELL"], !env.isEmpty {
    shellLogger.info("Using SHELL env: \(env)")
    return env
  }

  var pwd = passwd()
  var result: UnsafeMutablePointer<passwd>?
  let bufSize = sysconf(_SC_GETPW_R_SIZE_MAX)
  let size = bufSize > 0 ? Int(bufSize) : 1024
  var buffer = [CChar](repeating: 0, count: size)
  let lookup = getpwuid_r(getuid(), &pwd, &buffer, buffer.count, &result)
  if lookup == 0, let result, let shell = result.pointee.pw_shell {
    let value = String(cString: shell)
    if !value.isEmpty {
      shellLogger.info("Using passwd shell: \(value)")
      return value
    }
  }

  shellLogger.info("Using fallback: /bin/zsh")
  return "/bin/zsh"
}

private actor ShellOutputAccumulator {
  private var stdoutLines: [String] = []
  private var stderrLines: [String] = []

  func append(_ line: String, source: ShellStreamSource) {
    switch source {
    case .stdout:
      stdoutLines.append(line)
    case .stderr:
      stderrLines.append(line)
    }
  }

  func output(exitCode: Int32) -> ShellOutput {
    ShellOutput(
      stdout: ShellOutputAccumulator.normalized(lines: stdoutLines),
      stderr: ShellOutputAccumulator.normalized(lines: stderrLines),
      exitCode: exitCode
    )
  }

  private static func normalized(lines: [String]) -> String {
    lines.joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

nonisolated private func lineStream(from handle: FileHandle) -> AsyncStream<String> {
  AsyncStream { continuation in
    let buffer = LockIsolated(Data())
    handle.readabilityHandler = { readableHandle in
      let chunk = readableHandle.availableData
      if chunk.isEmpty {
        readableHandle.readabilityHandler = nil
        if let remainingLine = buffer.withValue({ data -> String? in
          guard !data.isEmpty else {
            return nil
          }
          let value = String(bytes: data, encoding: .utf8) ?? ""
          data.removeAll(keepingCapacity: false)
          return value
        }) {
          continuation.yield(remainingLine)
        }
        continuation.finish()
        return
      }
      let lines = buffer.withValue { data in
        data.append(chunk)
        return consumeLines(from: &data)
      }
      lines.forEach { continuation.yield($0) }
    }
    continuation.onTermination = { _ in
      handle.readabilityHandler = nil
    }
  }
}

nonisolated func consumeLines(from buffer: inout Data) -> [String] {
  var lines: [String] = []
  // Break on LF, CR, and CRLF so `\r`-rewritten progress (e.g. `git clone
  // --progress`, which overwrites one line with carriage returns) streams live
  // instead of only at LF phase boundaries.
  while let breakIndex = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
    // A lone trailing CR may be the first half of a CRLF split across two reads;
    // leave it buffered so we never emit a phantom empty segment between them.
    if buffer[breakIndex] == 0x0D, breakIndex == buffer.index(before: buffer.endIndex) {
      break
    }
    lines.append(String(bytes: buffer.prefix(upTo: breakIndex), encoding: .utf8) ?? "")
    let afterBreak = buffer.index(after: breakIndex)
    if buffer[breakIndex] == 0x0D, afterBreak < buffer.endIndex, buffer[afterBreak] == 0x0A {
      buffer.removeSubrange(...afterBreak)
    } else {
      buffer.removeSubrange(...breakIndex)
    }
  }
  return lines
}
