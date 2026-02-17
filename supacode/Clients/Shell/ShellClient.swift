import ComposableArchitecture
import Darwin
import Foundation

enum ShellProcessEvent: Sendable {
  case stdoutLine(String)
  case stderrLine(String)
  case completed(ShellOutput)
}

nonisolated struct ShellClient {
  var run: @Sendable (URL, [String], URL?) async throws -> ShellOutput
  var runLoginImpl: @Sendable (URL, [String], URL?, Bool) async throws -> ShellOutput

  func runLogin(
    _ executableURL: URL,
    _ arguments: [String],
    _ currentDirectoryURL: URL?,
    log: Bool = true
  ) async throws -> ShellOutput {
    var output: ShellOutput?
    for try await event in runLoginStream(executableURL, arguments, currentDirectoryURL, log: log) {
      if case let .completed(shellOutput) = event {
        output = shellOutput
      }
    }
    guard let output else {
      let command = ([executableURL.path(percentEncoded: false)] + arguments).joined(separator: " ")
      throw ShellClientError(command: command, stdout: "", stderr: "", exitCode: -1)
    }
    return output
  }

  func runLoginStream(
    _ executableURL: URL,
    _ arguments: [String],
    _ currentDirectoryURL: URL?,
    log: Bool = true
  ) -> AsyncThrowingStream<ShellProcessEvent, Error> {
    let shellURL = URL(fileURLWithPath: defaultShellPath())
    let execCommand = shellExecCommand(for: shellURL)
    let shellArguments =
      ["-l", "-c", execCommand, "--", executableURL.path(percentEncoded: false)] + arguments
    if log {
      let cwd = currentDirectoryURL?.path(percentEncoded: false) ?? "nil"
      let cmd = shellArguments.joined(separator: " ")
      shellLogger.debug("runLogin cwd=\(cwd) cmd=\(shellURL.path) \(cmd)")
    }
    return runProcessStream(
      executableURL: shellURL,
      arguments: shellArguments,
      currentDirectoryURL: currentDirectoryURL
    )
  }
}

extension ShellClient: DependencyKey {
  static let liveValue = ShellClient(
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
    }
  )

  static let testValue = ShellClient(
    run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
    runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
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
  var output: ShellOutput?
  for try await event in stream {
    switch event {
    case .stdoutLine:
      break
    case .stderrLine:
      break
    case .completed(let shellOutput):
      output = shellOutput
    }
  }
  guard let output else {
    let command = ([executableURL.path(percentEncoded: false)] + arguments).joined(separator: " ")
    throw ShellClientError(command: command, stdout: "", stderr: "", exitCode: -1)
  }
  return output
}

nonisolated private func runProcessStream(
  executableURL: URL,
  arguments: [String],
  currentDirectoryURL: URL?
) -> AsyncThrowingStream<ShellProcessEvent, Error> {
  AsyncThrowingStream { continuation in
    Task.detached {
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

      let stdoutTask = Task.detached {
        var stdout = ""
        for await line in outputHandle.bytes.lines {
          continuation.yield(.stdoutLine(line))
          stdout.append(contentsOf: line)
          stdout.append("\n")
        }
        return stdout.trimmingCharacters(in: .newlines)
      }
      let stderrTask = Task.detached {
        var stderr = ""
        for await line in errorHandle.bytes.lines {
          continuation.yield(.stderrLine(line))
          stderr.append(contentsOf: line)
          stderr.append("\n")
        }
        return stderr.trimmingCharacters(in: .newlines)
      }
      do {
        try process.run()
        process.waitUntilExit()
        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value
        let exitCode = process.terminationStatus
        if exitCode != 0 {
          let command = ([executableURL.path(percentEncoded: false)] + arguments).joined(separator: " ")
          let stdoutTrimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
          let stderrTrimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
          continuation.finish(
            throwing: ShellClientError(
              command: command,
              stdout: stdoutTrimmed,
              stderr: stderrTrimmed,
              exitCode: exitCode
            )
          )
          return
        }
        continuation.yield(
          .completed(
            ShellOutput(
              stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
              stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
              exitCode: exitCode
            )
          )
        )
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
  }
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
