import Foundation

public struct SettingsRepositorySummary: Equatable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var isGitRepository: Bool
  /// Lives on an SSH host. Partitions the settings sidebar into Local / Remote.
  /// A plain `Bool` rather than the concrete `RemoteHost`, which lives in the
  /// app module and isn't visible here.
  public var isRemote: Bool
  /// The repository's real root URL, used to key its per-repo settings. For a
  /// local repo this equals `URL(fileURLWithPath: id)`; for a remote repo `id`
  /// is a `remote:` key (not a path), so the bare remote path must be passed in
  /// explicitly so the settings key matches the worktree's `repositoryRootURL`.
  public var rootURL: URL

  public init(
    id: String,
    name: String,
    isGitRepository: Bool = true,
    isRemote: Bool = false,
    rootURL: URL? = nil
  ) {
    self.id = id
    self.name = name
    self.isGitRepository = isGitRepository
    self.isRemote = isRemote
    self.rootURL = (rootURL ?? URL(fileURLWithPath: id)).standardizedFileURL
  }
}
