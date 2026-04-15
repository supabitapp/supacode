import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

nonisolated final class LoginStreamCallRecorder: @unchecked Sendable {
  struct Snapshot {
    let executableURL: URL?
    let arguments: [String]
    let currentDirectoryURL: URL?
    let log: Bool
  }

  private let lock = NSLock()
  private var executableURLValue: URL?
  private var argumentsValue: [String] = []
  private var currentDirectoryURLValue: URL?
  private var logValue = true

  func record(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL?,
    log: Bool
  ) {
    lock.lock()
    executableURLValue = executableURL
    argumentsValue = arguments
    currentDirectoryURLValue = currentDirectoryURL
    logValue = log
    lock.unlock()
  }

  func snapshot() -> Snapshot {
    lock.lock()
    let value = Snapshot(
      executableURL: executableURLValue,
      arguments: argumentsValue,
      currentDirectoryURL: currentDirectoryURLValue,
      log: logValue
    )
    lock.unlock()
    return value
  }
}

struct ShellClientStreamingTests {
  @Test func runStreamYieldsStdoutAndStderrLines() async throws {
    let shell = ShellClient.liveValue
    let commandURL = URL(fileURLWithPath: "/bin/sh")
    let stream = shell.runStream(
      commandURL,
      ["-c", "printf 'out-1\\n'; printf 'err-1\\n' 1>&2; printf 'out-2\\n'"],
      nil
    )
    var stdoutLines: [String] = []
    var stderrLines: [String] = []
    var finishedOutput: ShellOutput?
    for try await event in stream {
      switch event {
      case .line(let line):
        switch line.source {
        case .stdout:
          stdoutLines.append(line.text)
        case .stderr:
          stderrLines.append(line.text)
        }
      case .finished(let output):
        finishedOutput = output
      }
    }

    #expect(stdoutLines == ["out-1", "out-2"])
    #expect(stderrLines == ["err-1"])
    #expect(finishedOutput == ShellOutput(stdout: "out-1\nout-2", stderr: "err-1", exitCode: 0))
  }

  @Test func runStreamYieldsLinesBeforeProcessFinishes() async throws {
    let shell = ShellClient.liveValue
    let commandURL = URL(fileURLWithPath: "/bin/sh")
    let stream = shell.runStream(
      commandURL,
      ["-c", "printf 'first\\n'; sleep 0.4; printf 'last\\n'"],
      nil
    )
    var sawFirstLine = false
    var finishedAfterFirstLine = false
    for try await event in stream {
      switch event {
      case .line(let line):
        if line.source == .stdout, line.text == "first" {
          sawFirstLine = true
        }
      case .finished:
        finishedAfterFirstLine = sawFirstLine
      }
    }

    #expect(sawFirstLine)
    #expect(finishedAfterFirstLine)
  }

  @Test func runStreamThrowsShellClientErrorOnNonZeroExit() async throws {
    let shell = ShellClient.liveValue
    let commandURL = URL(fileURLWithPath: "/bin/sh")
    let stream = shell.runStream(
      commandURL,
      ["-c", "printf 'out\\n'; printf 'err\\n' 1>&2; exit 7"],
      nil
    )
    var streamedLines: [ShellStreamLine] = []
    do {
      for try await event in stream {
        if case .line(let line) = event {
          streamedLines.append(line)
        }
      }
      Issue.record("Expected stream to throw for non-zero exit")
    } catch let shellError as ShellClientError {
      #expect(shellError.exitCode == 7)
      #expect(shellError.stdout == "out")
      #expect(shellError.stderr == "err")
      #expect(shellError.command.contains("/bin/sh"))
    }

    #expect(streamedLines.contains(where: { $0.source == .stdout && $0.text == "out" }))
    #expect(streamedLines.contains(where: { $0.source == .stderr && $0.text == "err" }))
  }

  @Test func runLoginStreamForwardsParameters() async throws {
    let recorder = LoginStreamCallRecorder()
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      },
      runLoginStreamImpl: { executableURL, arguments, currentDirectoryURL, log in
        recorder.record(
          executableURL: executableURL,
          arguments: arguments,
          currentDirectoryURL: currentDirectoryURL,
          log: log
        )
        return AsyncThrowingStream { continuation in
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    )
    let executableURL = URL(fileURLWithPath: "/usr/bin/env")
    let currentDirectoryURL = URL(fileURLWithPath: "/tmp")
    let stream = shell.runLoginStream(
      executableURL,
      ["echo", "hello"],
      currentDirectoryURL,
      log: false
    )
    for try await _ in stream {}

    let snapshot = recorder.snapshot()
    #expect(snapshot.executableURL == executableURL)
    #expect(snapshot.arguments == ["echo", "hello"])
    #expect(snapshot.currentDirectoryURL == currentDirectoryURL)
    #expect(snapshot.log == false)
  }
}
