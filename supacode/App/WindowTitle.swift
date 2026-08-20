import ComposableArchitecture
import Foundation
import OrderedCollections

/// Computes the macOS main-window title for the navigation title.
/// Format is `<repo> · <tab>` for a selected worktree (tab segment
/// dropped if absent), `Archive` for the archived view, and `Supacode`
/// when nothing is selected. The hosting `Window` scene's title and
/// the ⌘0 menu item stay `Supacode` regardless.
enum WindowTitle {
  static let appName = "Supacode"
  static let archivedLabel = "Archive"

  static func format(repo: String, tab: String?) -> String {
    guard let tab, !tab.isEmpty else { return repo }
    return "\(repo) · \(tab)"
  }

  @MainActor
  static func compute(
    repositories: RepositoriesFeature.State,
    terminalManager: WorktreeTerminalManager
  ) -> String {
    switch repositories.selection {
    case .archivedWorktrees:
      return archivedLabel
    case .worktree(let worktreeID):
      return worktreeTitle(
        worktreeID: worktreeID,
        repositories: repositories,
        terminalManager: terminalManager
      )
    case .failedRepository(let repositoryID):
      // A failed remote keeps a placeholder repository whose `name` is the
      // resolved display name; its id is a `user@host` authority, not a local
      // path, so deriving a name from a file URL would be garbage. Fall back to
      // the file-URL leaf only for a local failure with no placeholder.
      let fallback =
        repositories.repositories[id: repositoryID]?.name
        ?? Repository.name(for: URL(fileURLWithPath: repositoryID.rawValue).standardizedFileURL)
      // Failed repositories never entered the roster, so git-vs-folder is
      // unknown here; resolve the title the way the failed sidebar row does.
      let name = Repository.sidebarDisplayName(
        custom: repositories.sidebar.customTitleForUnloadedRepository(repositoryID),
        fallback: fallback
      )
      return format(repo: name, tab: "Unavailable")
    case .none:
      return appName
    }
  }

  @MainActor
  private static func worktreeTitle(
    worktreeID: Worktree.ID,
    repositories: RepositoriesFeature.State,
    terminalManager: WorktreeTerminalManager
  ) -> String {
    guard let repositoryID = repositories.repositoryID(containing: worktreeID),
      let repository = repositories.repositories[id: repositoryID]
    else {
      return appName
    }
    let repoTitle = repoDisplayName(
      repository: repository,
      repositories: repositories
    )
    let tabTitle = terminalManager.hostIfExists(for: worktreeID)?.focusedTab.flatMap { tab in
      sanitize(tab.customTitle ?? tab.title)
    }
    return format(repo: repoTitle, tab: tabTitle)
  }

  @MainActor
  private static func repoDisplayName(
    repository: Repository,
    repositories: RepositoriesFeature.State
  ) -> String {
    Repository.sidebarDisplayName(
      custom: repositories.sidebar.customTitle(for: repository),
      fallback: repository.name
    )
  }

  /// Strips control characters (incl. embedded `\n` that would
  /// truncate `NSWindow.title`) from a tab title, then trims edge
  /// whitespace. Returns `nil` if nothing remains.
  static func sanitize(_ raw: String) -> String? {
    let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    let trimmed = String(String.UnicodeScalarView(scalars))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
