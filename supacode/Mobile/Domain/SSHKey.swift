import Foundation

struct SSHKey: Identifiable, Codable, Equatable, Hashable, Sendable {
  let id: UUID
  var name: String
  let publicKey: String
  let fingerprint: String
  let createdAt: Date

  init(
    id: UUID = UUID(),
    name: String,
    publicKey: String,
    fingerprint: String,
    createdAt: Date = Date(),
  ) {
    self.id = id
    self.name = name
    self.publicKey = publicKey
    self.fingerprint = fingerprint
    self.createdAt = createdAt
  }
}
