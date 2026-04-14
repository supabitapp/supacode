import Foundation

public enum SettingsSection: Hashable {
  case general
  case notifications
  case worktree
  case developer
  case shortcuts
  case updates
  case github
  case repository(String)
  case repositoryScripts(String)

  /// The repository ID for repository-scoped sections.
  public var repositoryID: String? {
    switch self {
    case .repository(let id), .repositoryScripts(let id):
      id
    default:
      nil
    }
  }
}
