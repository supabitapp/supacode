import Foundation

@MainActor
final class TerminalIntentRegistry {
  static let shared = TerminalIntentRegistry()
  weak var terminalManager: WorktreeTerminalManager?
}

