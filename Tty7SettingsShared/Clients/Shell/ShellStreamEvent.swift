public nonisolated enum ShellStreamSource: Equatable, Sendable {
  case stdout
  case stderr
}

public nonisolated struct ShellStreamLine: Equatable, Sendable {
  public let source: ShellStreamSource
  public let text: String

  public init(source: ShellStreamSource, text: String) {
    self.source = source
    self.text = text
  }
}

public nonisolated enum ShellStreamEvent: Equatable, Sendable {
  case line(ShellStreamLine)
  case finished(ShellOutput)
}
