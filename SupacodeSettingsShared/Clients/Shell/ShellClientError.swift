import Foundation

public nonisolated struct ShellClientError: LocalizedError, Equatable, Sendable {
  public let command: String
  public let stdout: String
  public let stderr: String
  public let exitCode: Int32

  public init(command: String, stdout: String, stderr: String, exitCode: Int32) {
    self.command = command
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
  }

  public var errorDescription: String? {
    var parts: [String] = ["Command failed: \(command)"]
    if !stdout.isEmpty {
      parts.append("stdout:\n\(stdout)")
    }
    if !stderr.isEmpty {
      parts.append("stderr:\n\(stderr)")
    }
    return parts.joined(separator: "\n")
  }
}
