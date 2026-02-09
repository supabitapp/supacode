import AppIntents
import Foundation

enum TerminalIntentError: Error, LocalizedError, Sendable {
  case terminalNoLongerAvailable(id: UUID)

  var errorDescription: String? {
    switch self {
    case .terminalNoLongerAvailable:
      return "The selected terminal pane is no longer available."
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .terminalNoLongerAvailable:
      return "Try selecting a different terminal pane and run the shortcut again."
    }
  }
}

