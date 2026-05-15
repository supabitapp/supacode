import Foundation

nonisolated enum GithubCLIError: LocalizedError, Equatable {
  case unavailable
  case outdated
  case gatewayTimeout
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "GitHub CLI is unavailable"
    case .outdated:
      return "GitHub CLI is outdated. Update to the latest version."
    case .gatewayTimeout:
      return "GitHub returned a gateway timeout (HTTP 504)."
    case .commandFailed(let message):
      return message
    }
  }
}
