import Foundation

/// A parsed deeplink action from a `supacode://` URL.
enum Deeplink: Equatable, Sendable {
  case open
  case help
  case worktree(id: Worktree.ID, action: WorktreeAction)
  case repoOpen(path: URL)
  case repoWorktreeNew(
    repositoryID: Repository.ID,
    branch: String?,
    baseRef: String?,
    fetchOrigin: Bool
  )
  case settings(section: DeeplinkSettingsSection?)
  case settingsRepo(repositoryID: Repository.ID)

  enum WorktreeAction: Equatable, Sendable {
    case select
    case run
    case stop
    case runScript(scriptID: UUID)
    case stopScript(scriptID: UUID)
    case archive
    case unarchive
    case delete
    case pin
    case unpin
    case tab(tabID: UUID)
    case tabNew(input: String?, id: UUID?)
    case tabDestroy(tabID: UUID)
    case surface(tabID: UUID, surfaceID: UUID, input: String?)
    case surfaceSplit(tabID: UUID, surfaceID: UUID, direction: SplitDirection, input: String?, id: UUID?)
    case surfaceDestroy(tabID: UUID, surfaceID: UUID)
  }

  /// Settings sections reachable via deeplink.
  enum DeeplinkSettingsSection: String, Equatable, Sendable {
    case general
    case notifications
    case worktrees
    case developer
    case codingAgents
    case shortcuts
    case updates
    case github
  }
}
