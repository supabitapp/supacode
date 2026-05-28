import Foundation

enum GitLabCLIError: Error, Equatable {
  case unavailable
  case commandFailed(String)
}
