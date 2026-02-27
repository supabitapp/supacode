import Foundation

struct MobileSession: Identifiable, Equatable, Sendable {
  let id: UUID
  let serverID: MobileServer.ID
  var title: String
  let createdAt: Date
  var isClosed: Bool

  init(
    id: UUID = UUID(),
    serverID: MobileServer.ID,
    title: String,
    createdAt: Date = Date(),
    isClosed: Bool = false,
  ) {
    self.id = id
    self.serverID = serverID
    self.title = title
    self.createdAt = createdAt
    self.isClosed = isClosed
  }
}
