import OSLog

public nonisolated struct SupaLogger: Sendable {
  private let category: String
  #if !DEBUG
    private let logger: Logger
  #endif

  public init(_ category: String) {
    self.category = category
    #if !DEBUG
      self.logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: category)
    #endif
  }

  public func debug(_ message: String) {
    #if DEBUG
      print("[\(category)] \(message)")
    #else
      logger.notice("\(message, privacy: .public)")
    #endif
  }

  public func info(_ message: String) {
    #if DEBUG
      print("[\(category)] \(message)")
    #else
      logger.notice("\(message, privacy: .public)")
    #endif
  }

  public func warning(_ message: String) {
    #if DEBUG
      print("[\(category)] \(message)")
    #else
      logger.warning("\(message, privacy: .public)")
    #endif
  }
}
