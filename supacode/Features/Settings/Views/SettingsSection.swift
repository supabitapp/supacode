import Foundation

enum SettingsSection: Hashable {
  case general
  case notifications
  case worktree
  case shortcuts
  case updates
  case advanced
  case github
  case repository(Repository.ID)
}
