import Foundation

struct WorktreeInfoEntry: Equatable, Hashable, Identifiable {
  /// Matches the owning `Worktree.id`; lets `IdentifiedArrayOf<WorktreeInfoEntry>`
  /// stand in for the previous `[Worktree.ID: WorktreeInfoEntry]` dict storage.
  let id: Worktree.ID
  var addedLines: Int?
  var removedLines: Int?
  var pullRequest: GithubPullRequest?

  init(
    id: Worktree.ID,
    addedLines: Int? = nil,
    removedLines: Int? = nil,
    pullRequest: GithubPullRequest? = nil
  ) {
    self.id = id
    self.addedLines = addedLines
    self.removedLines = removedLines
    self.pullRequest = pullRequest
  }

  var isEmpty: Bool {
    addedLines == nil && removedLines == nil && pullRequest == nil
  }
}
