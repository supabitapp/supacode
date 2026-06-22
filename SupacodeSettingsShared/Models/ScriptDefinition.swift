import Foundation

/// A user-configured script that can be run on demand from the
/// toolbar, command palette, or keyboard shortcut. Each repository
/// stores an ordered array of these in `RepositorySettings.scripts`.
public nonisolated struct ScriptDefinition: Identifiable, Codable, Equatable, Hashable, Sendable {
  public var id: UUID
  public var kind: ScriptKind
  public var name: String
  public var command: String

  /// Per-instance overrides — only meaningful for `.custom` kinds.
  /// Predefined kinds always resolve to the kind default.
  public var systemImage: String?
  public var tintColor: RepositoryColor?

  /// Display name for toolbar labels: predefined types show their
  /// kind name ("Run", "Test"), custom types show user-defined name.
  public nonisolated var displayName: String {
    kind == .custom ? name : kind.defaultName
  }

  /// Resolved SF Symbol name: predefined types always use the kind
  /// default so future icon changes propagate automatically.
  public nonisolated var resolvedSystemImage: String {
    kind == .custom ? (systemImage ?? kind.defaultSystemImage) : kind.defaultSystemImage
  }

  /// Resolved tint color: predefined types always use the kind
  /// default so future color changes propagate automatically.
  public nonisolated var resolvedTintColor: RepositoryColor {
    kind == .custom ? (tintColor ?? kind.defaultTintColor) : kind.defaultTintColor
  }

  public nonisolated init(
    id: UUID = UUID(),
    kind: ScriptKind,
    name: String? = nil,
    systemImage: String? = nil,
    tintColor: RepositoryColor? = nil,
    command: String = ""
  ) {
    self.id = id
    self.kind = kind
    self.name = name ?? kind.defaultName
    self.systemImage = systemImage
    self.tintColor = tintColor
    self.command = command
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, name, command, systemImage, tintColor
  }

  /// Optional fields use `try?` so a malformed `tintColor` / `systemImage`
  /// drops just that override rather than the whole script entry.
  public nonisolated init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    kind = try container.decode(ScriptKind.self, forKey: .kind)
    name = try container.decode(String.self, forKey: .name)
    command = try container.decode(String.self, forKey: .command)
    systemImage = (try? container.decodeIfPresent(String.self, forKey: .systemImage)) ?? nil
    tintColor = (try? container.decodeIfPresent(RepositoryColor.self, forKey: .tintColor)) ?? nil
  }
}

/// Where a `ScriptDefinition` is owned. Repo scripts shadow globals on ID
/// collisions (see `merged`), so a definition resolves to `.repo` whenever
/// it lives in the repository's settings, otherwise `.global`.
public enum ScriptScope: String, Codable, Hashable, Sendable {
  case repo
  case global
}

// MARK: - Collection helpers

extension [ScriptDefinition] {
  /// The first `.run`-kind script — the primary toolbar action.
  public var primaryScript: ScriptDefinition? {
    first { $0.kind == .run }
  }

  /// Whether any `.run`-kind script is currently running.
  public func hasRunningRunScript(in runningIDs: Set<UUID>) -> Bool {
    contains { $0.kind == .run && runningIDs.contains($0.id) }
  }

  /// Repo scripts followed by globals; repo wins on ID collisions.
  public static func merged(
    repo: [ScriptDefinition],
    global: [ScriptDefinition]
  ) -> [ScriptDefinition] {
    let repoIDs = Set(repo.map(\.id))
    return repo + global.filter { !repoIDs.contains($0.id) }
  }
}
