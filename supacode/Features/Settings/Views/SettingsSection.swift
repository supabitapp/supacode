import Foundation

enum SettingsSection: Hashable {
  case general
  case notifications
  case codingAgents
  case worktree
  case updates
  case advanced
  case github
  case repository(Repository.ID)
}
