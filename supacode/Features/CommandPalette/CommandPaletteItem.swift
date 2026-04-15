import Sharing
import SupacodeSettingsShared

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
    case openSettings
    case newWorktree
    case removeWorktree(Worktree.ID, Repository.ID)
    case archiveWorktree(Worktree.ID, Repository.ID)
    case viewArchivedWorktrees
    case refreshWorktrees
    case ghosttyCommand(String)
    case openPullRequest(Worktree.ID)
    case markPullRequestReady(Worktree.ID)
    case mergePullRequest(Worktree.ID)
    case closePullRequest(Worktree.ID)
    case copyFailingJobURL(Worktree.ID)
    case copyCiFailureLogs(Worktree.ID)
    case rerunFailedJobs(Worktree.ID)
    case openFailingCheckDetails(Worktree.ID)
    #if DEBUG
      case debugTestToast(RepositoriesFeature.StatusToast)
    #endif
  }

  var isGlobal: Bool {
    switch kind {
    case .checkForUpdates, .openRepository, .openSettings, .newWorktree, .viewArchivedWorktrees,
      .refreshWorktrees:
      true
    case .ghosttyCommand:
      false
    case .openPullRequest,
      .markPullRequestReady,
      .mergePullRequest,
      .closePullRequest,
      .copyFailingJobURL,
      .copyCiFailureLogs,
      .rerunFailedJobs,
      .openFailingCheckDetails:
      true
    case .worktreeSelect, .removeWorktree, .archiveWorktree:
      false
    #if DEBUG
      case .debugTestToast:
        true
    #endif
    }
  }

  var isRootAction: Bool {
    switch kind {
    case .checkForUpdates, .openRepository, .openSettings, .newWorktree, .viewArchivedWorktrees,
      .refreshWorktrees:
      true
    case .ghosttyCommand:
      false
    case .openPullRequest,
      .markPullRequestReady,
      .mergePullRequest,
      .closePullRequest,
      .copyFailingJobURL,
      .copyCiFailureLogs,
      .rerunFailedJobs,
      .openFailingCheckDetails,
      .worktreeSelect,
      .removeWorktree,
      .archiveWorktree:
      false
    #if DEBUG
      case .debugTestToast:
        false
    #endif
    }
  }

  var appShortcut: AppShortcut? {
    switch kind {
    case .checkForUpdates: AppShortcuts.checkForUpdates
    case .openRepository: AppShortcuts.openRepository
    case .openSettings: AppShortcuts.openSettings
    case .newWorktree: AppShortcuts.newWorktree
    case .viewArchivedWorktrees: AppShortcuts.archivedWorktrees
    case .refreshWorktrees: AppShortcuts.refreshWorktrees
    case .ghosttyCommand: nil
    case .openPullRequest: AppShortcuts.openPullRequest
    case .markPullRequestReady,
      .mergePullRequest,
      .closePullRequest,
      .copyFailingJobURL,
      .copyCiFailureLogs,
      .rerunFailedJobs,
      .openFailingCheckDetails,
      .worktreeSelect,
      .removeWorktree,
      .archiveWorktree:
      nil
    #if DEBUG
      case .debugTestToast:
        nil
    #endif
    }
  }

  var appShortcutLabel: String? {
    effectiveAppShortcut?.display
  }

  var appShortcutSymbols: [String]? {
    effectiveAppShortcut?.displaySymbols
  }

  private var effectiveAppShortcut: AppShortcut? {
    guard let shortcut = appShortcut else { return nil }
    @Shared(.settingsFile) var settingsFile
    return shortcut.effective(from: settingsFile.global.shortcutOverrides)
  }
}
