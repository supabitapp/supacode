import Foundation

/// Action to perform automatically when a worktree's pull request is merged.
///
/// Use as `MergedWorktreeAction?` where `nil` means no automatic action.
public nonisolated enum MergedWorktreeAction: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
  case archive

  /// Deletes the worktree. Whether the local branch is also deleted
  /// depends on the `deleteBranchOnDeleteWorktree` setting.
  case delete

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .archive: return "Archive"
    case .delete: return "Delete"
    }
  }
}
