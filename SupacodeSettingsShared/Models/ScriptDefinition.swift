import Foundation

/// A user-configured script that can be run on demand from the
/// toolbar, command palette, or keyboard shortcut. Each repository
/// stores an ordered array of these in `RepositorySettings.scripts`.
public nonisolated struct ScriptDefinition: Identifiable, Codable, Equatable, Hashable, Sendable {
  public var id: UUID
  public var kind: ScriptKind
  public var name: String
  public var systemImage: String
  public var tintColor: TerminalTabTintColor
  public var command: String

  public nonisolated init(
    id: UUID = UUID(),
    kind: ScriptKind,
    name: String? = nil,
    systemImage: String? = nil,
    tintColor: TerminalTabTintColor? = nil,
    command: String = ""
  ) {
    self.id = id
    self.kind = kind
    self.name = name ?? kind.defaultName
    self.systemImage = systemImage ?? kind.defaultSystemImage
    self.tintColor = tintColor ?? kind.defaultTintColor
    self.command = command
  }
}
