import Foundation

nonisolated final class GitShellInvocationRecorder: @unchecked Sendable {
  struct Snapshot {
    let executableURL: URL?
    let arguments: [String]
    let currentDirectoryURL: URL?
  }

  private let lock = NSLock()
  private var executableURLValue: URL?
  private var argumentsValue: [String] = []
  private var currentDirectoryURLValue: URL?

  func record(executableURL: URL, arguments: [String], currentDirectoryURL: URL?) {
    lock.lock()
    executableURLValue = executableURL
    argumentsValue = arguments
    currentDirectoryURLValue = currentDirectoryURL
    lock.unlock()
  }

  func snapshot() -> Snapshot {
    lock.lock()
    let value = Snapshot(
      executableURL: executableURLValue,
      arguments: argumentsValue,
      currentDirectoryURL: currentDirectoryURLValue
    )
    lock.unlock()
    return value
  }
}
