import Foundation

/// Action to perform automatically when a worktree's pull request is merged.
///
/// As a repository override, use `MergedWorktreeAction?` where `nil` inherits
/// the global setting.
public nonisolated enum MergedWorktreeAction: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
  /// Take no automatic action. The default.
  case ignore

  case archive

  /// Deletes the worktree. Whether the local branch is also deleted
  /// depends on the `deleteBranchOnDeleteWorktree` setting.
  case delete

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .ignore: return "Do nothing"
    case .archive: return "Archive"
    case .delete: return "Delete"
    }
  }
}
