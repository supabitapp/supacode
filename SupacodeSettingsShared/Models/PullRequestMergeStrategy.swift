import Foundation

public nonisolated enum PullRequestMergeStrategy: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
  case merge
  case squash
  case rebase

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .merge:
      return "Merge"
    case .squash:
      return "Squash"
    case .rebase:
      return "Rebase"
    }
  }

  public var ghArgument: String {
    rawValue
  }
}
