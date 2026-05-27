import Foundation

struct Worktree: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let detail: String
  let workingDirectory: URL
  let repositoryRootURL: URL
  let createdAt: Date?
  /// The admin entry exists but the working dir is gone on disk.
  /// Drives the orphan UI (warning icon, gated open actions).
  let isMissing: Bool
  /// `false` for detached-HEAD git worktrees and folder synthetics. Gates
  /// branch-targeted actions so they don't reach a `git branch -m` call
  /// that has no real ref to operate on.
  let isAttached: Bool

  nonisolated init(
    id: String,
    name: String,
    detail: String,
    workingDirectory: URL,
    repositoryRootURL: URL,
    createdAt: Date? = nil,
    isMissing: Bool = false,
    isAttached: Bool = true
  ) {
    self.id = id
    self.name = name
    self.detail = detail
    self.workingDirectory = workingDirectory
    self.repositoryRootURL = repositoryRootURL
    self.createdAt = createdAt
    self.isMissing = isMissing
    self.isAttached = isAttached
  }
}

extension Worktree {
  /// Base environment variables for Supacode scripts (supplemented per-surface).
  var scriptEnvironment: [String: String] {
    [
      "SUPACODE_WORKTREE_PATH": workingDirectory.path(percentEncoded: false),
      "SUPACODE_ROOT_PATH": repositoryRootURL.path(percentEncoded: false),
    ]
  }

}
