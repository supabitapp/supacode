import Foundation

struct NotificationLocation: Equatable, Sendable {
  let worktreeID: Worktree.ID
  let tabID: TerminalTabID
  let surfaceID: UUID
  let notificationID: UUID
}
