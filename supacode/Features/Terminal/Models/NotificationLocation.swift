import Foundation

struct NotificationLocation: Equatable, Sendable {
  let worktreeID: Worktree.ID
  let tabID: TabID
  let surfaceID: UUID
  let notificationID: UUID
}
