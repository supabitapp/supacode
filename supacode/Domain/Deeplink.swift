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
    fetchOrigin: Bool,
    worktreeName: String?,
    worktreePath: String?
  )
  case settings(section: DeeplinkSettingsSection?)
  case settingsRepo(repositoryID: Repository.ID)
  case settingsRepoScripts(repositoryID: Repository.ID)

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
    /// Raw appearance values from the URL; parsed at execution so the parser
    /// stays dumb. `nil` means the query item was omitted and should be preserved.
    case appearance(title: String?, color: String?)
    case tab(tabID: UUID)
    case tabNew(input: String?, id: UUID?, title: String? = nil)
    case tabRename(tabID: UUID, title: String)
    case tabDestroy(tabID: UUID)
    case surface(tabID: UUID, surfaceID: UUID, input: String?)
    case surfaceSplit(tabID: UUID, surfaceID: UUID, direction: SplitDirection, input: String?, id: UUID?)
    case surfaceDestroy(tabID: UUID, surfaceID: UUID)

    /// Whether dispatching this action should also select / focus the worktree.
    /// Metadata-only updates (appearance, tab rename) skip it so they don't steal focus.
    var selectsWorktree: Bool {
      switch self {
      case .appearance, .tabRename: false
      default: true
      }
    }
  }

  /// Settings sections reachable via deeplink.
  enum DeeplinkSettingsSection: String, Equatable, Sendable {
    case general
    case notifications
    case worktrees
    case developer
    case shortcuts
    case scripts
    case updates
    case github
  }
}
