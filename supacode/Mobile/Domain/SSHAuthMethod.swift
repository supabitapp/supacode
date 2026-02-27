import Foundation

enum SSHAuthMethod: Codable, Equatable, Hashable, Sendable {
  case none
  case password
  case sshKey(SSHKey.ID)

  private enum CodingKeys: String, CodingKey {
    case type
    case keyID
  }

  private enum AuthType: String, Codable {
    case none
    case password
    case sshKey
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(AuthType.self, forKey: .type)
    switch type {
    case .none:
      self = .none
    case .password:
      self = .password
    case .sshKey:
      let keyID = try container.decode(SSHKey.ID.self, forKey: .keyID)
      self = .sshKey(keyID)
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .none:
      try container.encode(AuthType.none, forKey: .type)
    case .password:
      try container.encode(AuthType.password, forKey: .type)
    case .sshKey(let keyID):
      try container.encode(AuthType.sshKey, forKey: .type)
      try container.encode(keyID, forKey: .keyID)
    }
  }
}
