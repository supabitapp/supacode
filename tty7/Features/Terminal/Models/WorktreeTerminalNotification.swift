import Foundation

struct WorktreeTerminalNotification: Identifiable, Equatable, Sendable {
  let id: UUID
  let surfaceID: UUID
  let title: String
  let body: String
  let createdAt: Date
  var isRead: Bool

  init(
    id: UUID = UUID(),
    surfaceID: UUID,
    title: String,
    body: String,
    createdAt: Date,
    isRead: Bool = false
  ) {
    self.id = id
    self.surfaceID = surfaceID
    self.title = title
    self.body = body
    self.createdAt = createdAt
    self.isRead = isRead
  }

  var content: String {
    [title, body].filter { !$0.isEmpty }.joined(separator: " - ")
  }
}
