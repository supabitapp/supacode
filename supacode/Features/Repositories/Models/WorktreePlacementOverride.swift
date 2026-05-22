import Foundation

/// Optional per-creation overrides from the New Worktree dialog's worktree
/// section, the `worktree-new` CLI command, and the `repo/.../worktree/new`
/// deeplink. `name` is the leaf folder name (default: the branch name); `path`
/// is the parent directory (default: the resolved base directory). Both `nil`
/// keeps `wt`'s default `base/<branch>` placement.
struct WorktreePlacementOverride: Equatable {
  var name: String?
  var path: String?
}

extension WorktreePlacementOverride {
  /// Validates a worktree-name leaf override. Returns an error message when the
  /// name would escape the parent folder or collide with git internals, or
  /// `nil` when it is empty (use the default) or acceptable. Shared by the
  /// prompt, the reducer create path, and the CLI / deeplink entry points.
  nonisolated static func nameValidationError(_ name: String?) -> String? {
    let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    guard !trimmed.contains("/"), !trimmed.contains("\\") else {
      return "Worktree name can't contain slashes."
    }
    guard trimmed != ".", trimmed != "..", trimmed.lowercased() != ".git" else {
      return "Worktree name is invalid."
    }
    return nil
  }
}
