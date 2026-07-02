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

  @Test func runStreamSplitsCarriageReturnProgressLines() async throws {
    // `git clone --progress` rewrites one line with `\r`; the tokenizer must
    // surface each update as its own line, not buffer until the closing `\n`.
    let shell = ShellClient.liveValue
    let stream = shell.runStream(
      URL(fileURLWithPath: "/bin/sh"),
      ["-c", "printf 'p-1\\rp-2\\rp-3\\n'"],
      nil
    )
    var stdoutLines: [String] = []
    for try await event in stream {
      if case .line(let line) = event, line.source == .stdout {
        stdoutLines.append(line.text)
      }
    }
    #expect(stdoutLines == ["p-1", "p-2", "p-3"])
  }

  @Test func runStreamTreatsCRLFAsSingleBreak() async throws {
    let shell = ShellClient.liveValue
    let stream = shell.runStream(
      URL(fileURLWithPath: "/bin/sh"),
      ["-c", "printf 'a\\r\\nb\\r\\n'"],
      nil
    )
    var stdoutLines: [String] = []
    for try await event in stream {
      if case .line(let line) = event, line.source == .stdout {
        stdoutLines.append(line.text)
      }
    }
    #expect(stdoutLines == ["a", "b"])
  }

  @Test func consumeLinesDefersTrailingCarriageReturnAcrossReads() {
    // A lone trailing CR could be the first half of a CRLF split across reads;
    // it must be buffered, not emitted as a phantom empty line before the LF.
    var buffer = Data("a\r".utf8)
    #expect(consumeLines(from: &buffer).isEmpty)
    buffer.append(Data("\nb\r\n".utf8))
    #expect(consumeLines(from: &buffer) == ["a", "b"])
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

  @Test func readToEndOrDeadlineReturnsAllBytesOnEOF() async {
    // A closed write end reaches EOF well inside the deadline, so the reader
    // returns the full payload rather than an empty deadline result.
    let pipe = Pipe()
    let payload = Data("codex-cli 1.2.3\n".utf8)
    pipe.fileHandleForWriting.write(payload)
    try? pipe.fileHandleForWriting.close()

    let data = await ShellClient.readToEndOrDeadline(
      from: pipe.fileHandleForReading, deadlineSeconds: 60)
    #expect(data == payload)
  }
}
