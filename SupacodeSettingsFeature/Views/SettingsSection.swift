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
}
