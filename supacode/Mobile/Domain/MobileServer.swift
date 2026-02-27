import Foundation

struct MobileServer: Identifiable, Codable, Equatable, Hashable, Sendable {
  let id: UUID
  var name: String
  var host: String
  var username: String
  var port: Int
  var defaultCommand: String
  var authMethod: SSHAuthMethod

  init(
    id: UUID = UUID(),
    name: String = "",
    host: String = "",
    username: String = "",
    port: Int = 22,
    defaultCommand: String = "",
    authMethod: SSHAuthMethod = .none,
  ) {
    self.id = id
    self.name = name
    self.host = host
    self.username = username
    self.port = port
    self.defaultCommand = defaultCommand
    self.authMethod = authMethod
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, host, username, port, defaultCommand, authMethod
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    host = try container.decode(String.self, forKey: .host)
    username = try container.decode(String.self, forKey: .username)
    port = try container.decode(Int.self, forKey: .port)
    defaultCommand = try container.decode(String.self, forKey: .defaultCommand)
    authMethod = try container.decodeIfPresent(SSHAuthMethod.self, forKey: .authMethod) ?? .none
  }

  var displayName: String {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalizedName.isEmpty ? normalizedHost : normalizedName
  }

  var hostIsValid: Bool {
    !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var portIsValid: Bool {
    (1 ... 65535).contains(port)
  }

  var detailLine: String {
    let safeUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    let safeHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = safeUsername.isEmpty ? safeHost : "\(safeUsername)@\(safeHost)"
    return "\(prefix):\(port)"
  }

  func normalized() -> MobileServer {
    MobileServer(
      id: id,
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      host: host.trimmingCharacters(in: .whitespacesAndNewlines),
      username: username.trimmingCharacters(in: .whitespacesAndNewlines),
      port: max(1, min(port, 65535)),
      defaultCommand: defaultCommand.trimmingCharacters(in: .whitespacesAndNewlines),
      authMethod: authMethod,
    )
  }
}

extension MobileServer {
  func terminalCommand(overrideCommand: String?, identityFilePath: String? = nil) -> String? {
    let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedHost.isEmpty else { return nil }
    guard (1 ... 65535).contains(port) else { return nil }

    let destination = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? normalizedHost
      : "\(username.trimmingCharacters(in: .whitespacesAndNewlines))@\(normalizedHost)"

    var command: [String] = ["ssh", "-p", "\(port)"]
    if let identityFilePath {
      command.append(contentsOf: ["-i", identityFilePath, "-o", "IdentitiesOnly=yes"])
    }
    command.append(destination)
    if let override = overrideCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
      !override.isEmpty
    {
      command.append(Self.shellEscape(override))
    } else if !defaultCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      command.append(Self.shellEscape(defaultCommand.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    return command.joined(separator: " ")
  }

  private static func shellEscape(_ value: String) -> String {
    if value.isEmpty {
      return "''"
    }
    return "'" + value.replacing("'", with: "'\\''") + "'"
  }
}
