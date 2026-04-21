import Foundation

struct WorktreeTerminalNotification: Identifiable, Equatable, Sendable {
  let id: UUID
  let surfaceId: UUID
  let title: String
  let body: String
  let createdAt: Date
  var isRead: Bool

  init(
    id: UUID = UUID(),
    surfaceId: UUID,
    title: String,
    body: String,
    createdAt: Date,
    isRead: Bool = false
  ) {
    self.id = id
    self.surfaceId = surfaceId
    self.title = title
    self.body = body
    self.createdAt = createdAt
    self.isRead = isRead
  }

  var content: String {
    [title, body].filter { !$0.isEmpty }.joined(separator: " - ")
  }
}
