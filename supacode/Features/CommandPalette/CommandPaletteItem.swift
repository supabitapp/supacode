struct CommandPaletteItem: Identifiable, Equatable {
  static let defaultPriorityTier = 100

  let id: String
  let title: String
  let subtitle: String?
  let kind: Kind
  let priorityTier: Int

  init(
    id: String,
    title: String,
    subtitle: String?,
    kind: Kind,
    priorityTier: Int = defaultPriorityTier
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.kind = kind
    self.priorityTier = priorityTier
  }

  enum Kind: Equatable {
    case checkForUpdates
    case openRepository
    case worktreeSelect(Worktree.ID)
    case taskSelect(CodingTask.ID)
    case openSettings
    case newWorktree
    case newTask
    case removeWorktree(Worktree.ID, Repository.ID)
    case archiveWorktree(Worktree.ID, Repository.ID)
    case archiveTask(CodingTask.ID)
    case refreshWorktrees
    case openPullRequest(Worktree.ID)
    case markPullRequestReady(Worktree.ID)
    case mergePullRequest(Worktree.ID)
    case copyCiFailureLogs(Worktree.ID)
    case rerunFailedJobs(Worktree.ID)
    case openFailingCheckDetails(Worktree.ID)
    #if DEBUG
      case debugTestToast(RepositoriesFeature.StatusToast)
    #endif
  }

  var isGlobal: Bool {
    switch kind {
    case .checkForUpdates, .openRepository, .openSettings, .newWorktree, .newTask, .refreshWorktrees:
      return true
    case .openPullRequest,
      .markPullRequestReady,
      .mergePullRequest,
      .copyCiFailureLogs,
      .rerunFailedJobs,
      .openFailingCheckDetails:
      return true
    case .worktreeSelect, .taskSelect, .removeWorktree, .archiveWorktree, .archiveTask:
      return false
    #if DEBUG
      case .debugTestToast:
        return true
    #endif
    }
  }

  var isRootAction: Bool {
    switch kind {
    case .checkForUpdates, .openRepository, .openSettings, .newWorktree, .newTask, .refreshWorktrees:
      return true
    case .openPullRequest,
      .markPullRequestReady,
      .mergePullRequest,
      .copyCiFailureLogs,
      .rerunFailedJobs,
      .openFailingCheckDetails,
      .worktreeSelect,
      .taskSelect,
      .removeWorktree,
      .archiveWorktree,
      .archiveTask:
      return false
    #if DEBUG
      case .debugTestToast:
        return false
    #endif
    }
  }

  var appShortcut: AppShortcut? {
    switch kind {
    case .checkForUpdates:
      return AppShortcuts.checkForUpdates
    case .openRepository:
      return AppShortcuts.openRepository
    case .openSettings:
      return AppShortcuts.openSettings
    case .newWorktree, .newTask:
      return AppShortcuts.newWorktree
    case .refreshWorktrees:
      return AppShortcuts.refreshWorktrees
    case .openPullRequest:
      return AppShortcuts.openPullRequest
    case .markPullRequestReady,
      .mergePullRequest,
      .copyCiFailureLogs,
      .rerunFailedJobs,
      .openFailingCheckDetails,
      .worktreeSelect,
      .taskSelect,
      .removeWorktree,
      .archiveWorktree,
      .archiveTask:
      return nil
    #if DEBUG
      case .debugTestToast:
        return nil
    #endif
    }
  }

  var appShortcutLabel: String? {
    appShortcut?.display
  }

  var appShortcutSymbols: [String]? {
    appShortcut?.displaySymbols
  }
}
