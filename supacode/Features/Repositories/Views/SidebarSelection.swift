enum SidebarSelection: Hashable {
  case worktree(Worktree.ID)
  case archivedWorktrees
  case failedRepository(Repository.ID)

  var worktreeID: Worktree.ID? {
    switch self {
    case .worktree(let id):
      return id
    case .archivedWorktrees, .failedRepository:
      return nil
    }
  }

  var failedRepositoryID: Repository.ID? {
    switch self {
    case .failedRepository(let id):
      return id
    case .worktree, .archivedWorktrees:
      return nil
    }
  }
}
