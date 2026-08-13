import Foundation

/// A parsed deeplink action from a `supacode://` URL.
enum Deeplink: Equatable, Sendable {
  case open
  case help
  case worktree(id: Worktree.ID, action: WorktreeAction, background: Bool = false)
  case repoOpen(path: URL)
  case repoWorktreeNew(
    repositoryID: Repository.ID,
    branch: String?,
    baseRef: String?,
    /// Raw `upstream` query value (omitted / empty / ref); parsed at execution
    /// so the parser stays dumb.
    upstream: String? = nil,
    fetchOrigin: Bool,
    worktreeName: String?,
    worktreePath: String?,
    background: Bool = false,
    pin: Bool = false,
    /// Opt-in to checking out an existing, unused local branch rather than
    /// refusing the name. Never allows a branch checked out elsewhere.
    reuseExistingBranch: Bool = false
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
    case tabNew(input: String?, id: UUID?, title: String? = nil, pane: UUID? = nil)
    case tabRename(tabID: UUID, title: String)
    case tabDestroy(tabID: UUID)
    /// Moves a tab into a fresh split neighboring its current pane.
    case tabMove(tabID: UUID, direction: TerminalSplitMenuDirection)
    /// Focus the pane resolved from a token (its own id, or a tab / content it hosts).
    case paneFocus(token: UUID)
    /// Move focus to the pane neighboring the focused one.
    case paneFocusDirection(direction: TerminalSplitMenuDirection)
    /// Split a pane, opening a fresh tab in the new pane. `token` is the pane's
    /// own id or the id of a tab / content it hosts.
    case paneSplit(token: UUID, direction: SplitDirection, input: String?, id: UUID?)
    case paneDestroy(token: UUID)
    case paneZoom(token: UUID)
    /// Toggle window mode for the pane addressed by `token`.
    case paneWindow(token: UUID)
    case paneEqualize
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
