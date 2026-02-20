import ComposableArchitecture
import Darwin
import Foundation

nonisolated struct ShellClient: Sendable {
  var run: @Sendable (URL, [String], URL?) async throws -> ShellOutput
  var runLoginImpl: @Sendable (URL, [String], URL?, Bool) async throws -> ShellOutput
  var runStream: @Sendable (URL, [String], URL?) -> AsyncThrowingStream<ShellStreamEvent, Error>
  var runLoginStreamImpl: @Sendable (URL, [String], URL?, Bool) -> AsyncThrowingStream<ShellStreamEvent, Error>

  init(
    run: @escaping @Sendable (URL, [String], URL?) async throws -> ShellOutput,
    runLoginImpl: @escaping @Sendable (URL, [String], URL?, Bool) async throws -> ShellOutput,
    runStream: (@Sendable (URL, [String], URL?) -> AsyncThrowingStream<ShellStreamEvent, Error>)? = nil,
    runLoginStreamImpl:
      (@Sendable (URL, [String], URL?, Bool) -> AsyncThrowingStream<ShellStreamEvent, Error>)? = nil
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
    self.runLoginStreamImpl =
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
  }

  func runLogin(
    _ executableURL: URL,
    _ arguments: [String],
    _ currentDirectoryURL: URL?,
    log: Bool = true
  ) async throws -> ShellOutput {
    try await runLoginImpl(executableURL, arguments, currentDirectoryURL, log)
  }

  func runLoginStream(
    _ executableURL: URL,
    _ arguments: [String],
    _ currentDirectoryURL: URL?,
    log: Bool = true
  ) -> AsyncThrowingStream<ShellStreamEvent, Error> {
    runLoginStreamImpl(executableURL, arguments, currentDirectoryURL, log)
  }
}

extension ShellClient: DependencyKey {
  nonisolated static let live = ShellClient(
    run: { executableURL, arguments, currentDirectoryURL in
      try await runProcess(
        executableURL: executableURL,
        arguments: arguments,
        currentDirectoryURL: currentDirectoryURL
      )
    },
    runLoginImpl: { executableURL, arguments, currentDirectoryURL, log in
      let shellURL = URL(fileURLWithPath: defaultShellPath())
      let execCommand = shellExecCommand(for: shellURL)
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
      let shellURL = URL(fileURLWithPath: defaultShellPath())
      let execCommand = shellExecCommand(for: shellURL)
      let shellArguments =
        ["-l", "-c", execCommand, "--", executableURL.path(percentEncoded: false)] + arguments
      if log {
        let cwd = currentDirectoryURL?.path(percentEncoded: false) ?? "nil"
        let cmd = shellArguments.joined(separator: " ")
        shellLogger.debug("runLoginStream cwd=\(cwd) cmd=\(shellURL.path) \(cmd)")
      }
      return runProcessStream(
        executableURL: shellURL,
        arguments: shellArguments,
        currentDirectoryURL: currentDirectoryURL
      )
    }
  )

  static let liveValue = live

  static let testValue = ShellClient(
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
  var shellClient: ShellClient {
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
  AsyncThrowingStream { continuation in
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

nonisolated private func shellExecCommand(for shellURL: URL) -> String {
  switch shellURL.lastPathComponent {
  case "fish":
    return "test -f ~/.config/fish/config.fish; and source ~/.config/fish/config.fish >/dev/null 2>&1; exec $argv"
  case "bash":
    return "[ -f ~/.bashrc ] && . ~/.bashrc >/dev/null 2>&1; exec \"$@\""
  default:
    return "[ -f ~/.zshrc ] && . ~/.zshrc >/dev/null 2>&1; exec \"$@\""
  }
}

nonisolated private func defaultShellPath() -> String {
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

nonisolated private func consumeLines(from buffer: inout Data) -> [String] {
  var lines: [String] = []
  while let newlineIndex = buffer.firstIndex(of: 0x0A) {
    var lineData = buffer.prefix(upTo: newlineIndex)
    if lineData.last == 0x0D {
      lineData = lineData.dropLast()
    }
    lines.append(String(bytes: lineData, encoding: .utf8) ?? "")
    buffer.removeSubrange(...newlineIndex)
  }
  return lines
}
