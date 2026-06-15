public nonisolated struct ShellOutput: Equatable, Sendable {
  public let stdout: String
  public let stderr: String
  public let exitCode: Int32

  public init(stdout: String, stderr: String, exitCode: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
  }
}
