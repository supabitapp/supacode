enum SidebarSelection: Hashable {
  case worktree(Worktree.ID)
  case task(CodingTask.ID)
  case archivedWorktrees
  case archivedTasks
  case repository(Repository.ID)

  var worktreeID: Worktree.ID? {
    switch self {
    case .worktree(let id):
      return id
    case .task, .archivedWorktrees, .archivedTasks, .repository:
      return nil
    }
  }

  var taskID: CodingTask.ID? {
    switch self {
    case .task(let id):
      return id
    case .worktree, .archivedWorktrees, .archivedTasks, .repository:
      return nil
    }
  }
}
