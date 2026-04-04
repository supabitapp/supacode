import Foundation

enum SettingsSection: Hashable {
  case general
  case notifications
  case worktree
  case codingAgents
  case shortcuts
  case updates
  case github
  case repository(Repository.ID)
}
