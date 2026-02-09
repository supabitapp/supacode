import Foundation

@MainActor
final class TerminalIntentRegistry {
  static let shared = TerminalIntentRegistry()

  var terminalManager: WorktreeTerminalManager?

  private init() {}

  func setTerminalManager(_ terminalManager: WorktreeTerminalManager) {
    self.terminalManager = terminalManager
  }
}
