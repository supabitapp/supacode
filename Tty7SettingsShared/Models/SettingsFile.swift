public nonisolated struct SettingsFile: Codable, Equatable, Sendable {
  public var global: GlobalSettings
  public var repositories: [String: RepositorySettings]
  public var repositoryRoots: [String]
  public var pinnedWorktreeIDs: [String]

  enum CodingKeys: String, CodingKey {
    case global
    case repositories
    case repositoryRoots
    case pinnedWorktreeIDs
  }

  public static let `default` = SettingsFile(
    global: .default,
    repositories: [:],
    repositoryRoots: [],
    pinnedWorktreeIDs: []
  )

  public init(
    global: GlobalSettings = .default,
    repositories: [String: RepositorySettings] = [:],
    repositoryRoots: [String] = [],
    pinnedWorktreeIDs: [String] = []
  ) {
    self.global = global
    self.repositories = repositories
    self.repositoryRoots = repositoryRoots
    self.pinnedWorktreeIDs = pinnedWorktreeIDs
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    global = try container.decodeIfPresent(GlobalSettings.self, forKey: .global) ?? .default
    repositories =
      try container.decodeIfPresent([String: RepositorySettings].self, forKey: .repositories)
      ?? [:]
    repositoryRoots = try container.decodeIfPresent([String].self, forKey: .repositoryRoots) ?? []
    pinnedWorktreeIDs = try container.decodeIfPresent([String].self, forKey: .pinnedWorktreeIDs) ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(global, forKey: .global)
    try container.encode(repositories, forKey: .repositories)
    try container.encode(repositoryRoots, forKey: .repositoryRoots)
    try container.encode(pinnedWorktreeIDs, forKey: .pinnedWorktreeIDs)
  }
}
