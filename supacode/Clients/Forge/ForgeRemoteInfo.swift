import Foundation

struct ForgeRemoteInfo: Equatable, Sendable {
  let forge: Forge
  let host: String
  let owner: String
  let repo: String
}
