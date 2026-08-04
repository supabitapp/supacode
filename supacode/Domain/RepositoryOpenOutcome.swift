import Foundation

/// What an `openRepositories` request actually did with one requested path.
///
/// `repo open` used to answer the CLI `{"ok": true}` the moment the action was
/// dispatched, so a path that resolved to nothing — or to a worktree that was
/// never surfaced — still exited 0. Reporting the outcome per path lets the ack
/// say "adopted this" or "here's why not", and never "fine" by default.
struct RepositoryOpenOutcome: Equatable, Sendable {
  /// The path as requested, used to correlate back to the waiting command.
  let requestedURL: URL
  let result: Result

  enum Result: Equatable, Sendable {
    /// The path resolved to a repository root that is now open. `isNew` is false
    /// when it was already open, which still counts as success: the caller's
    /// postcondition ("this repo is available") holds either way.
    case repository(id: Repository.ID, isNew: Bool)
    /// The path was a linked worktree; the repository is open and the worktree
    /// has been selected. This is the case that previously succeeded silently
    /// while leaving the worktree unsurfaced.
    case worktree(id: Worktree.ID, repositoryID: Repository.ID)
    /// Nothing was adopted. `message` explains why, and the CLI exits non-zero.
    case failed(message: String)
  }

  /// The id a caller should be handed back for a successful open, if any.
  var resourceID: String? {
    switch result {
    case .repository(let id, _): id.rawValue
    case .worktree(let id, _): id.rawValue
    case .failed: nil
    }
  }

  var failureMessage: String? {
    guard case .failed(let message) = result else { return nil }
    return message
  }
}
